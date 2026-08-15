# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Pinspec
  module Runner
    class Sandbox
      PROBE_DIR = "tmp/pinspec"

      # One probe file per run. A fixed path means two pinspec runs against the same
      # application overwrite each other's probe between boots, and the result is not
      # an error: the stability filter compares one target's observations against
      # another's and reports the target as unstable, or crashes looking up a case id
      # that belongs to a different corpus. Silent and wrong, which is worse than a
      # lock. `pinspec pin app/services` is sequential, but a developer with two
      # terminals or a CI that fans out is not.
      def self.probe_filename(pid: Process.pid, object_id: nil)
        "probe-#{pid}-#{object_id || rand(1 << 24)}.rb"
      end

      DEFAULT_TIMEOUT = 600

      FORCED_ENV = {
        "DISABLE_SPRING" => "1",
        "TZ" => "UTC",
        "RAILS_ENV" => "test"
      }.freeze

      SCRUBBED_ENV = Runtime::BUNDLER_VARS.to_h { |name| [name, nil] }.freeze

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
        @probe_path ||= File.join(@app_root, PROBE_DIR, self.class.probe_filename(object_id: object_id))
      end

      def write_probe!
        FileUtils.mkdir_p(File.dirname(probe_path))
        File.write(probe_path, @probe_source)
        probe_path
      end

      def capture(boots: 2)
        write_probe!

        results = (1..boots).map { |run| execute(run: run, seed: 40 + run) }

        # Removed only on success. A probe left behind after a failure is the
        # evidence; one left behind after every run just fills tmp/ with files a
        # reader cannot tell apart.
        FileUtils.rm_f(probe_path)
        results
      end

      def runtime
        @runtime ||= Runtime.for(@app_root)
      end

      private

      def execute(run:, seed:)
        command = runner_command
        env = runtime.env
              .merge(FORCED_ENV)
              .merge("PINSPEC_SHUFFLE_SEED" => seed.to_s)
              .merge(@env)

        stdout, stderr, status = Open3.capture3(env, *command, chdir: @app_root)

        unless status.success?
          raise ProbeFailure,
                "the probe exited #{status.exitstatus} in #{@app_root}.\n" \
                "#{runtime.note ? "#{runtime.note}\n\n" : ''}" \
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

        relative = File.join(PROBE_DIR, File.basename(probe_path))

        if File.file?(File.join(@app_root, "Gemfile"))
          ["bundle", "exec", "rails", "runner", relative]
        else
          ["rails", "runner", relative]
        end
      end
    end
  end
end
