# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# M-11's backend boundary. The spike (docs/spike-m11-mutation-adapter.md) settled
# three things that these examples hold in place, because each one was learned the
# hard way and is invisible from the call site: the backend selects by NAME, its two
# options are not independent, and it must NOT be handed the app's gemset.
RSpec.describe Pinspec::Validate::MutationAdapter do
  let(:bin_dir) { File.join(Dir.mktmpdir, "bin") }
  let(:app_dir) { Dir.mktmpdir }

  # A stand-in backend, so the contract can be tested without a 3.4-only gem being
  # installed. It records its own argv, which is the thing under test.
  def fake_backend(stdout:, exit_status: 0)
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, "mutineer")
    File.write(path, <<~SH)
      #!/bin/bash
      printf '%s\\n' "$@" > #{File.join(app_dir, 'argv.txt')}
      env > #{File.join(app_dir, 'env.txt')}
      #{stdout}
      exit #{exit_status}
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def with_backend_on_path(**kwargs)
    fake_backend(**kwargs)
    original = ENV.fetch("PATH", "")
    ENV["PATH"] = "#{bin_dir}#{File::PATH_SEPARATOR}#{original}"
    yield
  ensure
    ENV["PATH"] = original
  end

  def argv
    File.read(File.join(app_dir, "argv.txt")).lines.map(&:chomp)
  end

  def child_env
    File.read(File.join(app_dir, "env.txt")).lines.each_with_object({}) do |line, out|
      key, value = line.chomp.split("=", 2)
      out[key] = value
    end
  end

  def adapter(test_command: nil)
    described_class.new(
      source_path: File.join(app_dir, "app/services/invoice_calculator.rb"),
      subject: "InvoiceCalculator#call", cwd: app_dir, test_command: test_command
    )
  end

  describe "refusing rather than exploding" do
    it "is unavailable with no backend on PATH" do
      original = ENV.fetch("PATH", "")
      ENV["PATH"] = File.join(app_dir, "empty")

      expect(described_class).not_to be_available
    ensure
      ENV["PATH"] = original
    end

    # The refusal has to teach, because the cause is a Ruby floor the user did not
    # choose and cannot see: pinspec runs on 3.2, the backend needs 3.4.
    it "names the Ruby floor, the install, and what is still usable" do
      allow(described_class).to receive(:available?).and_return(false)

      message = begin
        described_class.refuse_unless_available!
        nil
      rescue Pinspec::UnsupportedRailsVersion => e
        e.message
      end

      expect(message).to match(/Ruby >= 3\.4/)
      expect(message).to match(/gem install mutineer/)
      expect(message).to match(/only scoring is\s+gated/)
      expect(message).to match(/Ruby 3\.2/)
    end

    it "does not refuse when the backend is there" do
      allow(described_class).to receive(:available?).and_return(true)

      expect { described_class.refuse_unless_available! }.not_to raise_error
    end
  end

  describe "the command it builds" do
    let(:spec_path) { File.join(app_dir, "spec/pinspec/invoice_calculator_spec.rb") }

    it "selects the subject by name, not by line range" do
      with_backend_on_path(stdout: "echo '{}'") { adapter.score(spec_path) }

      expect(argv).to include("--only", "InvoiceCalculator#call")
    end

    it "passes paths relative to the app, since the backend runs chdir'd into it" do
      with_backend_on_path(stdout: "echo '{}'") { adapter.score(spec_path) }

      expect(argv).to include("app/services/invoice_calculator.rb")
      expect(argv).to include("spec/pinspec/invoice_calculator_spec.rb")
      expect(argv.grep(%r{^/})).to be_empty
    end

    # Strategy is not a free choice. Surgical redefinition needs a shared VM; a
    # test-command is a subprocess, so it forces whole-file reload. Getting this pair
    # wrong produces a silently meaningless score rather than an error.
    it "uses redefine in-process and reload behind a test command" do
      with_backend_on_path(stdout: "echo '{}'") do
        adapter.score(spec_path)
        expect(argv.each_cons(2)).to include(%w[--strategy redefine])
        expect(argv).not_to include("--test-command")

        adapter(test_command: "./run.sh %{files}").score(spec_path)
        expect(argv.each_cons(2)).to include(%w[--strategy reload])
        expect(argv.each_cons(2)).to include(["--test-command", "./run.sh %{files}"])
      end
    end
  end

  describe "the environment it hands over" do
    let(:spec_path) { File.join(app_dir, "spec/pinspec/x_spec.rb") }

    it "drops the bundler pins so a nested bundle exec finds the app's Gemfile" do
      with_backend_on_path(stdout: "echo '{}'") do
        adapter(test_command: "bundle exec rspec %{files}").score(spec_path)
      end

      expect(child_env).not_to have_key("BUNDLE_GEMFILE")
      expect(child_env).not_to have_key("RUBYOPT")
      expect(child_env["RAILS_ENV"]).to eq("test")
    end

    # The bug this prevents: handing the app's gemset to the backend hides the
    # backend from itself, and `mutineer` is then "not found" while plainly on PATH.
    it "leaves GEM_HOME alone, because that is how the backend finds its own gems" do
      expect(adapter.send(:environment)).not_to have_key("GEM_HOME")
      expect(adapter.send(:environment)).not_to have_key("GEM_PATH")
    end
  end

  describe "the outcome it returns" do
    let(:spec_path) { File.join(app_dir, "spec/pinspec/x_spec.rb") }

    let(:report) do
      {
        "summary" => { "score" => 66.7, "killed" => 2, "survived" => 1, "total" => 3 },
        "survivors" => [{ "operator" => "arithmetic", "line" => 12, "token" => "*", "extra" => "ignored" }]
      }
    end

    it "reads the report even when the backend chatters first" do
      outcome = with_backend_on_path(stdout: "echo 'loading 3 files'\necho '#{JSON.generate(report)}'") do
        adapter.score(spec_path)
      end

      expect(outcome).to be_scored
      expect(outcome.score).to eq(66.7)
      expect(outcome.killed).to eq(2)
      expect(outcome.survivors.first).to eq("operator" => "arithmetic", "line" => 12, "token" => "*")
    end

    # A backend that fails must not look like a pin that scored zero. Zero is a
    # finding; unscored is an absence of one.
    it "reports an unscored outcome, not a zero, when there is no report" do
      outcome = with_backend_on_path(stdout: "echo 'boom' >&2", exit_status: 1) { adapter.score(spec_path) }

      expect(outcome).not_to be_scored
      expect(outcome.score).to be_nil
      expect(outcome.raw).to include("boom")
    end

    it "survives a malformed report the same way" do
      outcome = with_backend_on_path(stdout: "echo '{not json'") { adapter.score(spec_path) }

      expect(outcome).not_to be_scored
    end
  end
end
