# frozen_string_literal: true

require "tmpdir"

# M-12. This report is the artifact a client reads instead of reading the pins, so
# the property under test is not "it renders" but "it cannot render a reassuring
# version of an unreassuring result". Every caveat here exists because the pin is
# narrower than it looks, and a report that omitted it would be worse than no report.
RSpec.describe Pinspec::Report::Summary do
  # The real fixture profile, read from files - no database - so the report is
  # rendered against shapes the rest of the pipeline actually produces.
  let(:app_root) { File.expand_path("../fixtures/apps/rails71_basic", __dir__) }
  let(:profile) { Pinspec::Analyzer::AppProfileReader.read(app_root) }
  let(:out_dir) { Dir.mktmpdir }

  let(:target) do
    Pinspec::Analyzer::TargetParser.parse(File.join(app_root, "app/services/invoice_calculator.rb"), "call")
  end

  let(:clock_target) do
    Pinspec::Analyzer::TargetParser.parse(File.join(app_root, "app/services/clock_reader.rb"), "call")
  end

  def verdict(id, observation, stable: true, cause: nil, diff: nil)
    Pinspec::Emit::StabilityFilter::Verdict.new(
      case_id: id, stable: stable, cause: cause, diff: diff, observation: observation
    )
  end

  def stability(verdicts)
    Pinspec::Emit::StabilityFilter::Report.new(verdicts: verdicts, runs: 2, compared_fields: %w[return_value])
  end

  def plan(isolation: :transaction, steps: [])
    Pinspec::SetupPlan.new(
      steps: steps, isolation: isolation,
      env_fingerprint: { tz: "UTC", locale: :en, zone: "UTC", seed: 42 },
      bindings: {}, notes: [], generation: 1, plan_id: "plan-abc123"
    )
  end

  def summary(**overrides)
    described_class.new(**{ app_root: out_dir, profile: profile, target: target, plan: plan,
                            corpus: Pinspec::InputCorpus.new(cases: [], setup_plan: nil),
                            stability: stability([verdict("c001", { "status" => "returned",
                                                                   "return_value" => { "t" => "int", "v" => 5 } })]) }
                           .merge(overrides))
  end

  describe "the frame it puts around everything" do
    # The single most important sentence in the document. A characterization pin of a
    # bug is a correct pin, and a reader who thinks otherwise will "fix" the pin.
    it "says plainly that a pin is not a judgement that the behaviour is right" do
      rendered = summary.render

      expect(rendered).to include("behaviour that exists TODAY")
      expect(rendered).to include("pinspec pins bugs on purpose")
    end

    it "records enough to reproduce the run" do
      rendered = summary.render

      expect(rendered).to include("InvoiceCalculator#call")
      expect(rendered).to include("plan-abc123")
      expect(rendered).to include("probe v#{Pinspec::PROBE_VERSION}")
      expect(rendered).to include("serializer v#{Pinspec::SERIALIZER_VERSION}")
      expect(rendered).to include(Pinspec::VERSION)
    end

    it "writes where a caller can find it" do
      path = summary.write!

      expect(path).to eq(File.join(out_dir, described_class::OUTPUT))
      expect(File.read(path)).to include("pinspec characterization report")
    end

    it "renders with nothing but a profile, so `analyze` can report on its own" do
      bare = described_class.new(app_root: out_dir, profile: profile)

      expect { bare.render }.not_to raise_error
      expect(bare.render).to include("(none)")
    end
  end

  describe "the caveats it refuses to bury" do
    it "declares a wildcarded value as asserting nothing about which integer" do
      rendered = summary(stability: stability([verdict("c001", { "status" => "returned",
                                                                "return_value" => { "t" => "seq" } })])).render

      expect(rendered).to include("Coverage caveats")
      expect(rendered).to include("nothing about which one")
    end

    it "declares truncation at the depth limit" do
      rendered = summary(stability: stability([verdict("c001", { "status" => "returned",
                                                                "return_value" => { "t" => "hash", "truncated" => true } })])).render

      expect(rendered).to include("truncated at the serializer's depth limit")
    end

    it "declares cases dropped for want of a world, rather than counting them as passes" do
      rendered = summary(stability: stability([
                                                verdict("c001", { "status" => "returned" }),
                                                verdict("c002", {}, stable: false, cause: :setup_error, diff: "NoMethodError")
                                              ])).render

      expect(rendered).to include("could not have a world built for them")
      expect(rendered).to include("What was NOT pinned")
      expect(rendered).to include("freeze an accident")
    end

    # Time.zone does not govern Time.now. A pin over a process-clock read holds only
    # under the TZ that captured it, and a reader has to be told before they trust it.
    it "declares a process-clock read and the TZ the pin is bound to" do
      rendered = summary(target: clock_target).render

      expect(rendered).to include("reads the process clock")
      expect(rendered).to include("`Time.zone` does not govern")
      expect(rendered).to include("TZ=UTC")
    end

    it "says nothing about the clock for a target that does not read it" do
      expect(summary.render).not_to include("reads the process clock")
    end
  end

  describe "the isolation regime, which the reader inherits whether they know it or not" do
    it "spells out that after_commit never fires under the transaction regime" do
      rendered = summary.render

      expect(rendered).to include("Isolation: transaction")
      expect(rendered).to include("rolled back")
      expect(rendered).to include("use_transactional_fixtures")
    end

    # The divergence from production that pinspec chooses not to hide: it does not
    # fake the callback, so the pin genuinely says less than production does.
    it "names the models whose callbacks are therefore unpinned" do
      with_callback = profile.with(
        model_findings: profile.model_findings +
                        [Pinspec::ModelFinding.new(kind: :after_commit, model: "Order",
                                                   file: "app/models/order.rb", line: 4)]
      )

      rendered = summary(profile: with_callback).render

      expect(rendered).to include("1 model(s) declare `after_commit`")
      expect(rendered).to include("Order")
      expect(rendered).to include("does not fake them")
      expect(rendered).to include("documented divergence from production")
    end

    # And says nothing when there is nothing to say, rather than printing an
    # ominous empty paragraph.
    it "stays quiet when no model declares one" do
      expect(profile.after_commit_models).to be_empty
      expect(summary.render).not_to include("does not fake them")
    end

    it "says the opposite, correctly, under truncation" do
      rendered = summary(plan: plan(isolation: :truncation)).render

      expect(rendered).to include("Isolation: truncation")
      expect(rendered).to include("`after_commit` callbacks **do** fire")
      expect(rendered).to include("truncated afterwards")
    end
  end

  describe "imported personal data" do
    let(:import_step) do
      Pinspec::SetupStep.new(
        kind: :import_record,
        payload: { name: "imported_customer_1", model: "Customer", source: "sha256:9f2c",
                   attributes: {}, redacted: %w[email name] }
      )
    end

    let(:rendered) { summary(plan: plan(steps: [import_step])).render }

    it "reports what was rewritten and what the rewrite preserved" do
      expect(rendered).to include("1 row(s) were imported from a real database")
      expect(rendered).to include("`email`")
      expect(rendered).to include("preserve **domain and length**")
    end

    # A redactor that changed behaviour would be worse than none, so the report has
    # to state the property, not just the fact that redaction happened.
    it "explains why a length-preserving rewrite matters" do
      expect(rendered).to include("routes on a domain or validates a length")
    end

    it "admits that no warning is not proof of no read" do
      expect(rendered).to include("no warning is not proof of no read")
    end

    it "keeps provenance hashed, so a committed spec maps to no production row" do
      expect(rendered).to include("`sha256:9f2c`")
      expect(rendered).to include("Sources are hashed")
      expect(rendered).not_to match(/\bid\s*=\s*\d+/)
    end

    it "says nothing about personal data when nothing was imported" do
      expect(summary.render).not_to include("Personal data")
    end
  end

  describe "verification and scoring" do
    def outcome(config, status)
      Pinspec::Verify::Verifier::Outcome.new(
        config: config, status: status, diagnosis: status == :green ? nil : :tz_dependent,
        detail: nil, examples: 3, failures: status == :green ? 0 : 1
      )
    end

    it "reports all three configurations and why one run would not do" do
      rendered = summary(outcomes: [outcome(:isolated, :green), outcome(:hostile, :green),
                                    outcome(:neighbored, :green)]).render

      expect(rendered).to include("repeatability rather than portability")
      expect(rendered).to include("| isolated | green | 3 |")
      expect(rendered).to include("neighbored")
    end

    # An omitted section reads as "nothing to say". For verification that would be a
    # lie of omission: a report written by `validate` carries scores and no
    # verification, and a client cannot tell that from a missing section.
    it "says verification was not run rather than omitting the section" do
      rendered = summary.render

      expect(rendered).to include("## Verification")
      expect(rendered).to include("**Not run in this pass.**")
      expect(rendered).to include("Run `pinspec pin`")
    end

    it "does not soften a failure" do
      rendered = summary(outcomes: [outcome(:isolated, :green), outcome(:hostile, :red)]).render

      expect(rendered).to include("**red** (tz_dependent)")
    end

    def score(aspect, value, verdict, survivors = [])
      Pinspec::Validate::PinScorer::Score.new(
        aspect: aspect, score: value, verdict: verdict, killed: 2, survived: survivors.size,
        survivors: survivors, note: nil
      )
    end

    let(:mutant) { { "operator" => "arithmetic", "line" => 12, "token" => "*" } }

    it "credits the pins together when nothing survived every aspect" do
      report = Pinspec::Validate::PinScorer::Report.new(
        subject: "InvoiceCalculator#call", skipped: [:mail],
        scores: [score(:return, 66.7, :weak, [{ "operator" => "m", "line" => 20, "token" => "perform_later" }]),
                 score(:jobs, 50.0, :weak, [mutant])]
      )

      rendered = summary(scores: report).render

      expect(rendered).to include("blind to different")
      expect(rendered).to include("| return | 66.7% (weak) |")
      expect(rendered).to include("No mutant survived every aspect")
    end

    it "names the real gap when one did" do
      report = Pinspec::Validate::PinScorer::Report.new(
        subject: "InvoiceCalculator#call", skipped: [],
        scores: [score(:return, 50.0, :weak, [mutant]), score(:jobs, 50.0, :weak, [mutant])]
      )

      rendered = summary(scores: report).render

      expect(rendered).to include("1 mutant(s) survived every aspect")
      expect(rendered).to include("`arithmetic` at line 12")
    end

    it "shows an unscored aspect as unscored, not as a zero" do
      report = Pinspec::Validate::PinScorer::Report.new(
        subject: "x", skipped: [], scores: [score(:mail, nil, :unscored)]
      )

      expect(summary(scores: report).render).to include("| mail | not scored |")
    end
  end

  describe "hazards found before the pin" do
    it "carries the application warnings through verbatim" do
      rendered = summary.render

      next if profile.warnings.empty?

      expect(rendered).to include("Application hazards")
      expect(rendered).to include(profile.warnings.first.lines.first.strip)
    end
  end
end
