# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Pinspec
  module Runner
    class Sandbox
      PROBE_DIR = "tmp/pinspec"
      PROBE_FILE = "probe.rb"

      DEFAULT_TIMEOUT = 600

      FORCED_ENV = {
        "DISABLE_SPRING" => "1",
        "TZ" => "UTC",
        "RAILS_ENV" => "test"
      }.freeze

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

      def capture(boots: 2)
        write_probe!

        (1..boots).map do |run|
          execute(run: run, seed: 40 + run)
        end
      end

      private

      def execute(run:, seed:)
        command = runner_command
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
