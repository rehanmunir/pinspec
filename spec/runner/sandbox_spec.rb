# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Pinspec::Runner::Sandbox do
  let(:app) { Dir.mktmpdir }

  def sandbox(source = "puts 1")
    described_class.new(app_root: app, probe_source: source)
  end

  # A fixed probe path means two pinspec runs against one application overwrite each
  # other's probe between boots. The result is not an error: the stability filter
  # compares one target's observations against another's and calls the target
  # unstable, or crashes looking up a case id belonging to a different corpus.
  # Silent and wrong.
  describe "one probe file per run" do
    it "gives two sandboxes different probe paths" do
      expect(sandbox.probe_path).not_to eq(sandbox.probe_path)
    end

    it "keeps the path stable within one sandbox" do
      one = sandbox

      expect(one.probe_path).to eq(one.probe_path)
    end

    it "names the file after the process, so a stray one can be traced" do
      expect(File.basename(sandbox.probe_path)).to include(Process.pid.to_s)
    end

    it "puts it where the docs say probes live" do
      expect(sandbox.probe_path).to start_with(File.join(app, described_class::PROBE_DIR))
    end

    it "runs the file it just wrote, not a fixed name" do
      one = sandbox
      one.write_probe!

      expect(one.send(:runner_command).last).to eq(
        File.join(described_class::PROBE_DIR, File.basename(one.probe_path))
      )
    end

    it "writes the source it was given" do
      one = sandbox("# hello")
      one.write_probe!

      expect(File.read(one.probe_path)).to eq("# hello")
    end
  end

  describe "what it scrubs" do
    it "removes bundler's variables but leaves the Ruby alone" do
      env = sandbox.runtime.env

      expect(env["BUNDLE_GEMFILE"]).to be_nil
      expect(env).to have_key("RUBYOPT")
      expect(env).not_to have_key("GEM_HOME")
    end

    it "forces the environment both hosts must share" do
      expect(described_class::FORCED_ENV)
        .to include("RAILS_ENV" => "test", "TZ" => "UTC", "DISABLE_SPRING" => "1")
    end
  end
end
