# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# What someone already using pinspec is entitled to when they upgrade. Every item
# here is something that broke, or nearly broke, on the way to 0.3.0.
RSpec.describe "upgrading from an earlier pinspec" do
  ROOT = File.expand_path("..", __dir__)

  def run_cli(*args)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "pinspec"), *args
    )

    [stdout.force_encoding("UTF-8"), stderr.force_encoding("UTF-8"), status]
  end

  def app
    File.join(ROOT, "spec/fixtures/apps/rails71_basic")
  end

  # A published exit code is an API. Reusing a retired number would silently change
  # what a caller's `if status == 11` means, which is worse than never returning it.
  describe "the exit-code table" do
    PUBLISHED = {
      1 => "UnparsableSource", 2 => "TargetNotFound", 3 => "AmbiguousTarget",
      4 => "BlockRequired", 5 => "UnresolvableSetup", 6 => "SchemaFormatUnsupported",
      7 => "ProbeFailure", 8 => "NothingStableToPin", 9 => "VerifyFailed",
      10 => "UnsupportedRailsVersion", 12 => "PinspecInternalError", 13 => "ConfigInvalid"
    }.freeze

    it "still means exactly what it meant in 0.1.0" do
      PUBLISHED.each do |code, name|
        expect(Pinspec.const_get(name).exit_code).to eq(code)
      end
    end

    # EnvironmentRefused was retired with the sampler's production guard. The number
    # must stay retired rather than being handed to something else.
    it "does not reuse 11, which a 0.1.0 script may still test for" do
      taken = Pinspec.constants
                     .map { |c| Pinspec.const_get(c) }
                     .select { |k| k.is_a?(Class) && k < Pinspec::Error }
                     .map(&:exit_code)

      expect(taken).not_to include(11)
    end
  end

  describe "a .pinspec.yml written for an older version" do
    around do |example|
      @config = File.join(app, Pinspec::Config::FILENAME)
      example.run
      FileUtils.rm_f(@config)
    end

    # `snapshot` was a valid key in 0.2.0. An upgrade must not turn someone's
    # committed config into a failing build.
    it "ignores a retired key with a note instead of failing" do
      File.write(@config, "cases: 3\nsnapshot: inline\n")

      stdout, stderr, status = run_cli("analyze", app)

      expect(status.exitstatus).to eq(0)
      expect(stderr).to include("snapshot")
      expect(stderr).to include("Ignoring")
      expect(stdout).to include("rails")
    end

    it "still refuses a key that was never valid" do
      File.write(@config, "cases: 3\nwibble: 1\n")

      _stdout, stderr, status = run_cli("analyze", app)

      expect(status.exitstatus).to eq(Pinspec::ConfigInvalid.exit_code)
      expect(stderr).to include("wibble")
    end
  end

  # 0.2.0 declared --snapshot. A script passing it should keep working, not die on an
  # unknown flag.
  describe "a retired flag" do
    # --snapshot was declared on `pin` only, in both 0.1.0 and 0.2.0.
    it "is accepted and ignored, with a note" do
      _stdout, stderr, _status = run_cli(
        "pin", File.join(app, "app/services/invoice_calculator.rb"), "--app", app,
        "--snapshot", "inline", "--skip-verify", "--cases", "1"
      )

      expect(stderr).to include("--snapshot was removed and is ignored")
      expect(stderr).not_to include("Usage:")
    end
  end

  # Nothing a 0.2.0 script could pass may have vanished. `snapshot` is absent here on
  # purpose: it is still accepted (see above) but no longer advertised, because
  # advertising a flag that does nothing invites people to keep passing it.
  describe "the flags each command accepted in 0.2.0" do
    {
      "plan" => %w[app cases],
      "capture" => %w[app cases boots compare-sql app-env sample no-redact],
      "pin" => %w[app cases boots verify-level skip-verify force app-env sample no-redact],
      "validate" => %w[app cases test-command app-env]
    }.each do |command, flags|
      it "still declares every flag #{command} had" do
        help, = run_cli("help", command)

        flags.each do |flag|
          expect(help).to include("--#{flag}"), "#{command} lost --#{flag}"
        end
      end
    end
  end

  # 0.1.0 documented `--app-env A=1 B=2 C=3`, because the option was an array. Every
  # command that takes it must still understand that form - `verify` did not, and was
  # caught by exercising the real upgrade path rather than by reasoning about it.
  describe "the 0.1.0 --app-env form" do
    %w[capture pin validate verify].each do |command|
      it "does not confuse #{command} into treating a pair as its target" do
        _stdout, stderr, _status = run_cli(
          command, "some_target.rb", "--app", app, "--app-env", "A=1", "B=2", "C=3"
        )

        expect(stderr).not_to include("was called with arguments"),
                              "#{command} read a KEY=VALUE pair as a positional argument"
        expect(stderr).not_to include("Usage:")
      end
    end
  end

  # Discovery follows the application's convention; 0.2.0 always assumed #call. If
  # those disagree, re-pinning would write a second file and leave the first one in
  # the suite, unmaintained and still running.
  describe "a class that is already pinned" do
    it "keeps the method the existing pin froze" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec/characterization"))
        FileUtils.mkdir_p(File.join(dir, "app/services"))

        File.write(File.join(dir, "app/services/dual_service.rb"), <<~RUBY)
          class DualService
            def call(x) = x
            def perform(x) = x * 2
          end
        RUBY
        FileUtils.touch(File.join(dir, "spec/characterization/dual_service_perform_spec.rb"))

        cli = Pinspec::CLI.new([], { "app" => dir })
        _file, method = cli.send(:resolve_target, File.join(dir, "app/services/dual_service.rb"))

        expect(method).to eq("perform")
      end
    end

    it "uses discovery when nothing is pinned yet" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/services"))
        File.write(File.join(dir, "app/services/dual_service.rb"), <<~RUBY)
          class DualService
            def call(x) = x
          end
        RUBY

        cli = Pinspec::CLI.new([], { "app" => dir })
        _file, method = cli.send(:resolve_target, File.join(dir, "app/services/dual_service.rb"))

        expect(method).to eq("call")
      end
    end
  end
end
