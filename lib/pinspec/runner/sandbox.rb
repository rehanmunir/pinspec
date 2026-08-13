# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Pinspec
  module Runner
    # Executes the generated probe inside the target application.
    #
    # Two boots by default (spec v0.3 §7 M-07, reversing v0.2): run two shares one
    # process's warm caches, so an input-keyed memo filled by run one's first case
    # is reused by every later case AND by all of run two - both runs agree while
    # the pinned value is an artifact of which case happened to run first. A boot
    # costs 10-30s; determinism is goal three.
    class Sandbox
      PROBE_DIR = "tmp/pinspec"
      PROBE_FILE = "probe.rb"

      DEFAULT_TIMEOUT = 600

      # Exported unconditionally. A stale Spring preloader serving yesterday's code
      # is a debugging evening deleted by one line (§12.10), and TZ=UTC removes one
      # axis of host drift.
      FORCED_ENV = {
        "DISABLE_SPRING" => "1",
        "TZ" => "UTC",
        "RAILS_ENV" => "test"
      }.freeze

      # Removed from the child's environment (nil deletes the variable).
      #
      # Without this, running pinspec from inside its own bundle - which is how
      # anyone would run it, `bundle exec pinspec pin ...` - leaks BUNDLE_GEMFILE
      # and RUBYOPT="-rbundler/setup" into the target app, so the app resolves
      # *pinspec's* Gemfile instead of its own and never boots. The failure is
      # bewildering ("Could not find prism-1.5.1") and has nothing to do with the
      # app being analysed.
      SCRUBBED_ENV = {
        "BUNDLE_GEMFILE" => nil,
        "BUNDLE_PATH" => nil,
        "BUNDLE_BIN_PATH" => nil,
        "BUNDLE_APP_CONFIG" => nil,
        "BUNDLER_VERSION" => nil,
        "BUNDLER_SETUP" => nil,
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "GEM_HOME" => nil,
        "GEM_PATH" => nil
      }.freeze

      Result = Data.define(:run, :observations, :env, :plan_id, :stderr) do
        def observation(case_id)
          observations.find { |o| o["case_id"] == case_id }
        end
      end

      def initialize(app_root:, probe_source:, timeout: DEFAULT_TIMEOUT, runner: nil, env: {})
        @app_root = app_root
        @probe_source = probe_source
        @timeout = timeout
        @runner = runner
        @env = env
      end

      def probe_path
        File.join(@app_root, PROBE_DIR, PROBE_FILE)
      end

      def write_probe!
        FileUtils.mkdir_p(File.dirname(probe_path))
        File.write(probe_path, @probe_source)
        probe_path
      end

      # Two boots, each shuffled with its own seed. Same script, same payload: any
      # difference between them is the target's, not pinspec's.
      def capture(boots: 2)
        write_probe!

        (1..boots).map do |run|
          execute(run: run, seed: 40 + run)
        end
      end

      private

      def execute(run:, seed:)
        command = runner_command
        # Scrub first, then force, then whatever the caller explicitly asked for:
        # an explicit GEM_HOME is a deliberate choice and must survive the scrub.
        env = SCRUBBED_ENV
              .merge(FORCED_ENV)
              .merge("PINSPEC_SHUFFLE_SEED" => seed.to_s)
              .merge(@env)

        stdout, stderr, status = Open3.capture3(env, *command, chdir: @app_root)

        unless status.success?
          raise ProbeFailure,
                "the probe exited #{status.exitstatus} in #{@app_root}.\n" \
                "#{stderr.to_s.lines.last(15).join}"
        end

        parse(stdout, stderr, run)
      end

      def parse(stdout, stderr, run)
        json = stdout.to_s.lines.reverse.find { |line| line.strip.start_with?("{") }

        if json.nil?
          raise ProbeFailure,
                "the probe produced no observations.\n" \
                "stdout: #{stdout.to_s.lines.last(10).join}\nstderr: #{stderr.to_s.lines.last(10).join}"
        end

        parsed = JSON.parse(json)

        Result.new(
          run: run,
          observations: parsed["observations"],
          env: parsed["env"],
          plan_id: parsed["plan_id"],
          stderr: stderr
        )
      rescue JSON::ParserError => e
        raise ProbeFailure, "the probe's output was not JSON (#{e.message}): #{json.to_s[0, 200]}"
      end

      # `bundle exec rails runner` when the app has a Gemfile, plain `rails runner`
      # otherwise. The app decides how it wants to be invoked.
      def runner_command
        return @runner if @runner

        relative = File.join(PROBE_DIR, PROBE_FILE)

        if File.file?(File.join(@app_root, "Gemfile"))
          ["bundle", "exec", "rails", "runner", relative]
        else
          ["rails", "runner", relative]
        end
      end
    end
  end
end
