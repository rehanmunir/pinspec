# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# M-11. The claim being tested is the one that justifies per-aspect scoring at all:
# aspects are blind to DIFFERENT mutations, so a single number over a whole pin
# hides both what it caught and what it missed. The spike measured this on a real
# service - a return-only run slept through a deleted `perform_later` that the
# job-only run killed - and these examples hold that reading in place.
RSpec.describe Pinspec::Validate::PinScorer do
  let(:app_dir) { Dir.mktmpdir }
  let(:bin_dir) { File.join(app_dir, "bin") }

  def verdict(id, observation)
    Pinspec::Emit::StabilityFilter::Verdict.new(
      case_id: id, stable: true, cause: nil, diff: nil, observation: observation
    )
  end

  def stability(*observations)
    Pinspec::Emit::StabilityFilter::Report.new(
      verdicts: observations.each_with_index.map { |o, i| verdict("c00#{i + 1}", o) },
      runs: 2, compared_fields: %w[return_value]
    )
  end

  def returned(extra = {})
    { "status" => "returned", "return_value" => { "t" => "int", "v" => 5 } }.merge(extra)
  end

  let(:target) do
    Pinspec::Analyzer::TargetParser.parse(
      File.expand_path("../fixtures/apps/rails71_basic/app/services/invoice_calculator.rb", __dir__), "call"
    )
  end

  def scorer(stability_report, env: {}, test_command: "./run.sh %{files}")
    described_class.new(
      app_root: app_dir, target: target, plan: nil, corpus: nil,
      stability: stability_report, fk_map: {}, env: env, test_command: test_command
    )
  end

  describe "which aspects it grades" do
    # A pin that asserts nothing about mail cannot be scored on mail: the run would
    # find no mutation that touches it and report a vacuous 100%.
    it "grades only the aspects the pin actually asserts" do
      report = stability(returned("enqueued_jobs" => [{ "job" => "SyncJob" }]))

      expect(scorer(report).send(:present_aspects)).to contain_exactly(:return, :jobs)
      expect(scorer(report).send(:excluded_aspects)).to contain_exactly(:error, :mail)
    end

    it "grades a raise as the error aspect, not the return aspect" do
      report = stability("status" => "raised", "error" => { "class" => "ArgumentError" })

      expect(scorer(report).send(:present_aspects)).to contain_exactly(:error)
    end

    it "grades mail when a delivery was pinned" do
      report = stability(returned("mail_deliveries" => [{ "to" => ["REDACTED"] }]))

      expect(scorer(report).send(:present_aspects)).to include(:mail)
    end
  end

  describe "the verdict it attaches to a score" do
    let(:plain) { scorer(stability(returned)) }

    it "grades on the spec's bands" do
      expect(plain.send(:verdict_for, :jobs, 95.0)).to eq(:strong)
      expect(plain.send(:verdict_for, :jobs, 80.0)).to eq(:strong)
      expect(plain.send(:verdict_for, :jobs, 55.0)).to eq(:weak)
      expect(plain.send(:verdict_for, :jobs, 40.0)).to eq(:weak)
      expect(plain.send(:verdict_for, :jobs, 12.0)).to eq(:worthless)
    end

    # The trap a bare score sets. A pin whose value is `{"t":"seq"}` asserts "some
    # integer" - it would survive almost any mutation of that value - so a high score
    # measures the mutations it DID catch and says nothing about the wildcard.
    it "refuses to call a wildcarded value strong, however well it scores" do
      wildcarded = scorer(stability(returned("return_value" => { "t" => "seq" })))

      expect(wildcarded.send(:verdict_for, :return, 100.0)).to eq(:weak)
      expect(wildcarded.send(:caveat_for, :return)).to include('{"t":"seq"}')
    end

    it "applies the same caution to a truncated value" do
      truncated = scorer(stability(returned("return_value" => { "t" => "str", "truncated" => true })))

      expect(truncated.send(:verdict_for, :return, 100.0)).to eq(:weak)
    end

    # A wildcard in the return value does not weaken the job assertion, which is a
    # different claim about a different thing.
    it "does not let a wildcarded return value taint the job aspect" do
      wildcarded = scorer(stability(returned("return_value" => { "t" => "seq" })))

      expect(wildcarded.send(:verdict_for, :jobs, 100.0)).to eq(:strong)
      expect(wildcarded.send(:caveat_for, :jobs)).to be_nil
    end
  end

  describe "the wrapper it generates for an app on its own Ruby" do
    it "is a plain bundle exec when the app shares pinspec's runtime" do
      expect(scorer(stability(returned), env: {}, test_command: nil).send(:generate_wrapper))
        .to eq("bundle exec rspec %{files}")
    end

    # The spike's finding: the backend scrubs inherited Ruby pins, so a legacy app on
    # its own rvm gemset has to re-establish its runtime inside the command.
    it "exports the app's runtime itself, because the backend scrubs what it inherits" do
      command = scorer(stability(returned), env: { "GEM_HOME" => "/gems/2.6" }, test_command: nil)
                .send(:generate_wrapper)

      script = File.read(File.join(app_dir, described_class::WRAPPER))

      expect(command).to include(described_class::WRAPPER)
      expect(script).to include('export GEM_HOME="/gems/2.6"')
      expect(script).to include('exec bundle exec rspec "$@"')
      expect(File.stat(File.join(app_dir, described_class::WRAPPER))).to be_executable
    end
  end

  describe "scoring a whole pin, aspect by aspect" do
    # Two aspects, each blind to what the other catches - the spike's actual reading,
    # reproduced here so the Report arithmetic is exercised on real shapes.
    ARITHMETIC = { "operator" => "arithmetic", "line" => 12, "token" => "*" }.freeze
    DELETED_JOB = { "operator" => "method_call", "line" => 20, "token" => "perform_later" }.freeze

    def backend!(reports)
      FileUtils.mkdir_p(bin_dir)
      path = File.join(bin_dir, "mutineer")
      branches = reports.map do |aspect, report|
        "    *#{aspect}_spec.rb) printf '%s\\n' '#{JSON.generate(report)}' ;;"
      end.join("\n")

      File.write(path, <<~SH)
        #!/bin/bash
        for arg in "$@"; do
          case "$arg" in
        #{branches}
          esac
        done
      SH
      FileUtils.chmod(0o755, path)
      path
    end

    def report_for(score, survivors)
      {
        "summary" => { "score" => score, "killed" => 2, "survived" => survivors.size,
                       "total" => 2 + survivors.size },
        "survivors" => survivors
      }
    end

    def run_with(reports, stability_report)
      backend!(reports)
      allow(Pinspec::Validate::MutationAdapter).to receive(:available?).and_return(true)
      allow(Pinspec::Validate::MutationAdapter).to receive(:find_executable)
        .and_return(File.join(bin_dir, "mutineer"))

      scorer = scorer(stability_report)
      allow(scorer).to receive(:write_variant) { |aspect| File.join(app_dir, "spec/aspects/#{aspect}_spec.rb") }
      scorer.run
    end

    let(:pinned) { stability(returned("enqueued_jobs" => [{ "job" => "SyncJob" }])) }

    let(:complementary) do
      run_with({ return: report_for(66.7, [DELETED_JOB]), jobs: report_for(50.0, [ARITHMETIC]) }, pinned)
    end

    it "scores each aspect in its own run, against its own spec file" do
      expect(complementary.scores.map(&:aspect)).to contain_exactly(:return, :jobs)
      expect(complementary.scores.map(&:score)).to contain_exactly(66.7, 50.0)
      expect(complementary.skipped).to contain_exactly(:error, :mail)
      expect(complementary.subject).to eq("InvoiceCalculator#call")
    end

    # The finding. Neither aspect is strong alone, and yet nothing got through the
    # pin - which is the argument for pinning all four aspects instead of the return
    # value everyone reaches for first.
    it "reports no real gap when every survivor was killed by some other aspect" do
      expect(complementary.surviving_all_aspects).to be_empty
      expect(complementary.covered_by_another_aspect.map { |s| s["token"] })
        .to contain_exactly("*", "perform_later")
    end

    it "does report a gap for a mutant that survived every aspect" do
      both_blind = run_with(
        { return: report_for(50.0, [ARITHMETIC, DELETED_JOB]), jobs: report_for(50.0, [ARITHMETIC]) },
        pinned
      )

      expect(both_blind.surviving_all_aspects.map { |s| s["token"] }).to contain_exactly("*")
      expect(both_blind.covered_by_another_aspect.map { |s| s["token"] }).to contain_exactly("perform_later")
    end

    it "summarises how much of the pin is strong" do
      strong_and_weak = run_with(
        { return: report_for(100.0, []), jobs: report_for(50.0, [ARITHMETIC]) }, pinned
      )

      expect(strong_and_weak.strong_ratio).to eq(50.0)
    end

    # An aspect the backend could not score must not be averaged in as a zero, and
    # must not silently vanish either.
    it "keeps an unscored aspect visible without letting it skew the ratio" do
      partial = run_with({ return: report_for(100.0, []) }, pinned)

      expect(partial.scores.map(&:aspect)).to contain_exactly(:return, :jobs)
      expect(partial.scored.map(&:aspect)).to contain_exactly(:return)
      expect(partial.scores.find { |s| s.aspect == :jobs }.verdict).to eq(:unscored)
      expect(partial.strong_ratio).to eq(100.0)
    end

    it "refuses to guess a gap when an aspect returned no survivor list" do
      # An empty survivor set means "nothing survived", so the intersection is empty
      # by definition - not "every other aspect's survivors are gaps".
      clean = run_with({ return: report_for(100.0, []), jobs: report_for(50.0, [ARITHMETIC]) }, pinned)

      expect(clean.surviving_all_aspects).to be_empty
    end

    it "refuses to score at all without the backend" do
      allow(Pinspec::Validate::MutationAdapter).to receive(:available?).and_return(false)

      expect { scorer(pinned).run }.to raise_error(Pinspec::UnsupportedRailsVersion, /mutineer/)
    end
  end
end
