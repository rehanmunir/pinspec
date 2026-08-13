# frozen_string_literal: true

RSpec.describe Pinspec::Verify::Verifier do
  subject(:verifier) { described_class.new(app_root: "/tmp/app", spec_path: "/tmp/app/spec/x_spec.rb") }

  describe "the configurations" do
    it "runs only the isolated one by default" do
      expect(verifier.configs).to eq([:isolated])
    end

    it "runs all three at full level" do
      full = described_class.new(app_root: "/tmp/app", spec_path: "/tmp/app/spec/x_spec.rb", level: :full)

      expect(full.configs).to eq(%i[isolated hostile neighbored])
    end

    it "changes TZ, locale and seed for the hostile run" do
      args, env = verifier.send(:arguments_for, :hostile)

      expect(env).to include("TZ" => "Etc/GMT+8", "LANG" => "C")
      expect(args).to include("--seed", "7")
    end

    it "picks a hostile timezone that differs from the capture's" do
      colliding = described_class.new(app_root: "/tmp/app", spec_path: "/tmp/app/spec/x_spec.rb",
                                     captured_tz: "Etc/GMT+8")

      _args, env = colliding.send(:arguments_for, :hostile)

      expect(env["TZ"]).not_to eq("Etc/GMT+8")
      expect(described_class::HOSTILE_TZ_CANDIDATES).to include(env["TZ"])
    end

    it "runs the file twice in one process for the neighbored run" do
      args, = verifier.send(:arguments_for, :neighbored)

      expect(args.count { |arg| arg.end_with?("x_spec.rb") }).to eq(2)
    end
  end

  describe "the environment" do
    it "scrubs the parent's bundler variables" do
      env = verifier.send(:environment)

      expect(env).to have_key("BUNDLE_GEMFILE")
      expect(env["BUNDLE_GEMFILE"]).to be_nil
      expect(env["RUBYOPT"]).to be_nil
      expect(env["RAILS_ENV"]).to eq("test")
    end

    it "runs under the timezone the capture ran under, not this shell's" do
      expect(verifier.send(:environment)["TZ"]).to eq(Pinspec::Runner::Sandbox::FORCED_ENV.fetch("TZ"))

      elsewhere = described_class.new(app_root: "/tmp/app", spec_path: "/tmp/app/spec/x_spec.rb",
                                     captured_tz: "Asia/Karachi")

      expect(elsewhere.send(:environment)["TZ"]).to eq("Asia/Karachi")
    end
  end

  describe "diagnosis" do
    def diagnose(text)
      found = described_class::DIAGNOSES.find { |pattern, _| text.match?(pattern) }
      found && found.last
    end

    it "names an unstubbed HTTP call" do
      expect(diagnose("WebMock::NetConnectNotAllowedError: real HTTP")).to eq(:unpinnable_http)
    end

    it "names a timezone-dependent pin" do
      expect(diagnose("pinspec: this pin was captured with TZ=UTC, but")).to eq(:tz_dependent)
    end

    it "names a seed-data collision" do
      expect(diagnose("ActiveRecord::RecordNotUnique")).to eq(:seed_collision)
    end

    it "names its own bug as its own" do
      expect(diagnose("uninitialized constant PinspecSerializer")).to eq(:pinspec_internal)
    end

    it "falls through honestly rather than guessing" do
      expect(diagnose("some entirely novel explosion")).to be_nil
    end
  end
end
