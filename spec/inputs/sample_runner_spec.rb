# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# M-06's live half. The sampler is the only part of planning that opens a database,
# and it is a SEPARATE process from the probe on purpose (spec v0.3 section 4b): it
# reads from `development` while the probe writes under `RAILS_ENV=test`. If those
# two ever shared a connection, a snapshot would stop being portable to the emitted
# spec, so the separation is the contract - not an implementation detail.
RSpec.describe Pinspec::Inputs::SampleRunner do
  let(:app_dir) { Dir.mktmpdir }
  let(:bin_dir) { File.join(app_dir, "bin") }

  # A stand-in `rails runner`, so the process boundary can be tested without a
  # booting Rails app. It records the environment it was handed.
  def fake_rails(body)
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, "rails")
    File.write(path, <<~SH)
      #!/bin/bash
      env > #{File.join(app_dir, 'env.txt')}
      printf '%s\\n' "$@" > #{File.join(app_dir, 'argv.txt')}
      #{body}
    SH
    FileUtils.chmod(0o755, path)
  end

  def with_fake_rails(body)
    fake_rails(body)
    original = ENV.fetch("PATH", "")
    ENV["PATH"] = "#{bin_dir}#{File::PATH_SEPARATOR}#{original}"
    yield
  ensure
    ENV["PATH"] = original
  end

  def child_env
    File.read(File.join(app_dir, "env.txt")).lines.each_with_object({}) do |line, out|
      key, value = line.chomp.split("=", 2)
      out[key] = value
    end
  end

  let(:requests) { [{ table: "customers", status_column: "status", limit: 3 }] }

  let(:payload) do
    {
      "env" => "development",
      "counts" => { "customers" => 2 },
      "rows" => { "customers" => [{ "id" => 1, "email" => "a@b.com" }] },
      "stratified" => { "customers" => [{ "id" => 1, "email" => "a@b.com" }, { "id" => 2, "email" => "c@d.com" }] },
      "errors" => []
    }
  end

  def fetch(body)
    with_fake_rails(body) { described_class.new(app_root: app_dir).fetch(requests) }
  end

  describe "the process it starts" do
    it "writes the generated script where the app can run it" do
      fetch("echo '#{JSON.generate(payload)}'")

      script = File.read(File.join(app_dir, described_class::SCRIPT_PATH))

      expect(script).to include("customers")
      expect(File.read(File.join(app_dir, "argv.txt"))).to include(described_class::SCRIPT_PATH)
    end

    # The reversal of v0.2's default. A test database is empty, and a sampler pointed
    # at an empty database silently degrades pinspec to boundary values while looking
    # like it worked.
    it "samples development by default, not test" do
      fetch("echo '#{JSON.generate(payload)}'")

      expect(child_env["RAILS_ENV"]).to eq("development")
    end

    it "lets the caller point it somewhere else" do
      with_fake_rails("echo '#{JSON.generate(payload)}'") do
        described_class.new(app_root: app_dir, rails_env: "staging").fetch(requests)
      end

      expect(child_env["RAILS_ENV"]).to eq("staging")
    end

    # Same scrub as the probe: pinspec's own Gemfile must not follow it into the app,
    # or the app boots against pinspec's gems and fails in a way that looks like the
    # app's fault.
    it "does not let pinspec's own bundle follow it into the app" do
      fetch("echo '#{JSON.generate(payload)}'")

      expect(child_env).not_to have_key("BUNDLE_GEMFILE")
      expect(child_env).not_to have_key("RUBYOPT")
      expect(child_env["TZ"]).to eq("UTC")
    end

    it "goes through bundler when the app has a Gemfile" do
      FileUtils.touch(File.join(app_dir, "Gemfile"))
      runner = described_class.new(app_root: app_dir)

      expect(runner.send(:command)).to eq(["bundle", "exec", "rails", "runner", described_class::SCRIPT_PATH])
    end
  end

  describe "reading the result" do
    it "finds the report even after the app logs over it" do
      result = fetch("echo 'DEPRECATION WARNING: whatever'\necho '#{JSON.generate(payload)}'")

      expect(result.env).to eq("development")
      expect(result.total_rows).to eq(2)
      expect(result).not_to be_empty
    end

    # Two overlapping slices - the quartile offsets and the status strata - so the
    # same row usually appears twice. Hydrating it twice would build two records that
    # are supposed to be one.
    it "deduplicates the sampled and stratified slices by primary key" do
      result = fetch("echo '#{JSON.generate(payload)}'")

      expect(result.rows_for("customers").map { |row| row["id"] }).to eq([1, 2])
      expect(result.all_rows.keys).to eq(["customers"])
    end

    it "reports an empty database as empty rather than as a failure" do
      empty = { "env" => "test", "counts" => { "customers" => 0 }, "rows" => {}, "stratified" => {}, "errors" => [] }
      result = fetch("echo '#{JSON.generate(empty)}'")

      expect(result).to be_empty
      expect(result.rows_for("customers")).to be_empty
    end

    it "tolerates a table it could not read at all" do
      result = fetch("echo '#{JSON.generate(payload.merge('rows' => {}))}'")

      expect(result.rows_for("customers").map { |row| row["id"] }).to eq([1, 2])
      expect(result.rows_for("orders")).to be_empty
    end
  end

  describe "failing loudly" do
    # Silence here would mean a corpus of boundary values presented as if it had been
    # drawn from real data, which is the one outcome worse than no sampling.
    it "raises with the app's own error when the script does not survive boot" do
      expect { fetch("echo 'ActiveRecord::NoDatabaseError' >&2\nexit 1") }
        .to raise_error(Pinspec::ProbeFailure, /exited 1.*NoDatabaseError/m)
    end

    it "raises when the script ran but produced no report" do
      expect { fetch("echo 'nothing to say'") }
        .to raise_error(Pinspec::ProbeFailure, /produced no rows/)
    end

    it "raises when the report is not JSON" do
      expect { fetch("echo '{ropey'") }
        .to raise_error(Pinspec::ProbeFailure, /not JSON/)
    end
  end
end
