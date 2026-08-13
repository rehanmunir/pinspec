# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Pinspec::Verify::Verifier, "refusing a green it did not earn" do
  let(:app) { Dir.mktmpdir }
  let(:bin) { File.join(app, "bin") }

  def rspec_reports(summary)
    FileUtils.mkdir_p(bin)
    path = File.join(bin, "bundle")
    File.write(path, <<~SH)
      #!/bin/bash
      printf '%s\\n' '#{JSON.generate("summary" => summary, "examples" => [])}'
    SH
    FileUtils.chmod(0o755, path)

    original = ENV.fetch("PATH", "")
    ENV["PATH"] = "#{bin}#{File::PATH_SEPARATOR}#{original}"
    yield
  ensure
    ENV["PATH"] = original
  end

  def verify(summary)
    FileUtils.mkdir_p(File.join(app, "spec"))
    FileUtils.touch(File.join(app, "spec", "x_spec.rb"))

    rspec_reports(summary) do
      described_class.new(app_root: app, spec_path: File.join(app, "spec/x_spec.rb")).verify.first
    end
  end

  it "calls a real pass green" do
    outcome = verify("example_count" => 3, "failure_count" => 0)

    expect(outcome).to be_green
    expect(outcome.examples).to eq(3)
  end

  it "refuses to call zero examples green" do
    outcome = verify("example_count" => 0, "failure_count" => 0)

    expect(outcome).not_to be_green
    expect(outcome.diagnosis).to eq(:no_examples_ran)
    expect(outcome.examples).to eq(0)
  end

  it "refuses when a load error was reported alongside passing examples" do
    outcome = verify("example_count" => 2, "failure_count" => 0,
                     "errors_outside_of_examples_count" => 1)

    expect(outcome).not_to be_green
    expect(outcome.diagnosis).to eq(:spec_load_error)
  end

  it "reads the load-error count from the top level too, for older rspec-core" do
    verifier = described_class.new(app_root: app, spec_path: "x")
    parsed = verifier.send(:parse, JSON.generate(
                                     "summary" => { "example_count" => 1, "failure_count" => 0 },
                                     "errors_outside_of_examples_count" => 2
                                   ))

    expect(parsed["errors_outside_of_examples_count"]).to eq(2)
  end

  it "still fails a genuine failure, with its own count" do
    outcome = verify("example_count" => 3, "failure_count" => 1)

    expect(outcome).not_to be_green
    expect(outcome.failures).to eq(1)
  end

  it "names a missing suite helper, which is what caused it" do
    found = described_class::DIAGNOSES.find do |pattern, _|
      "LoadError: cannot load such file -- rails_helper".match?(pattern)
    end

    expect(found.last).to eq(:spec_helper_missing)
  end
end
