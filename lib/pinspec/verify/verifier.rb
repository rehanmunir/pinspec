# frozen_string_literal: true

require "json"
require "open3"

module Pinspec
  module Verify
    # M-13. Runs the emitted spec inside the app's own rails_helper world and
    # diagnoses what happened.
    #
    # v0.2 ran it once, in isolation, on the capture machine, and called green "zero
    # manual edits" - which measures repeatability, not portability. The matrix
    # below is the same command under three environments, because every failure that
    # actually bites a client is invisible to the first one:
    #
    #   :isolated    the file alone, as captured
    #   :hostile     TZ, locale and RSpec seed all changed
    #   :neighbored  the file twice in one process, so accumulated state shows up
    class Verifier
      CONFIGS = %i[isolated hostile neighbored].freeze

      # :hostile must be hostile. A hardcoded timezone is not: for anyone whose
      # capture ran under Etc/GMT+8, the old constant made the hostile config
      # identical to the isolated one, so it reported green while proving nothing -
      # the exact failure mode this config exists to catch. Whichever candidate
      # differs from the capture's is used instead.
      HOSTILE_TZ_CANDIDATES = ["Etc/GMT+8", "Etc/GMT-6"].freeze

      Outcome = Data.define(:config, :status, :diagnosis, :detail, :examples, :failures) do
        def green?
          status == :green
        end

        def to_s
          green? ? "#{config}: green (#{examples} examples)" : "#{config}: #{status} (#{diagnosis})"
        end
      end

      # First match wins. Deliberately small, with an honest :unknown fallthrough -
      # rails_helper wildness is unbounded.
      DIAGNOSES = [
        [/WebMock::NetConnectNotAllowedError|VCR::Errors/, :unpinnable_http],
        [/captured with TZ=/, :tz_dependent],
        [/uninitialized constant PinspecSerializer|PinspecSerializer.*NoMethodError/, :pinspec_internal],
        [/RecordNotUnique|has already been taken/, :seed_collision],
        [/DatabaseCleaner/, :db_cleaner_strategy],
        [/cannot load such file -- (rails_helper|spec_helper)/, :spec_helper_missing],
        [/LoadError|cannot load such file/, :rails_helper_variance]
      ].freeze

      # `captured_tz` is the timezone the probe ran under, from the plan's
      # fingerprint. The emitted spec's clock guard is generated from that same
      # value, so :isolated has to run under it - "the file alone, as captured"
      # means as captured, not as this shell happens to be set.
      def initialize(app_root:, spec_path:, env: {}, level: :isolated,
                     captured_tz: Runner::Sandbox::FORCED_ENV.fetch("TZ"))
        @app_root = app_root
        @spec_path = spec_path
        @env = env
        @level = level
        @captured_tz = captured_tz
      end

      def configs
        @level == :full ? CONFIGS : [:isolated]
      end

      def verify
        configs.map { |config| run(config) }
      end

      private

      def run(config)
        args, extra_env = arguments_for(config)
        stdout, stderr, _status = Open3.capture3(environment.merge(extra_env), *args, chdir: @app_root)

        summary = parse(stdout)
        return failure(config, stdout, stderr, summary) if summary.nil? || summary["failure_count"].to_i.positive?

        # A run in which NOTHING RAN is not a pass. RSpec reports
        # `0 examples, 0 failures` and exits 0 when the file failed to LOAD - which is
        # what happened the first time this was pointed at a real application, whose
        # suite has no `rails_helper.rb` at all. The verifier said green three times
        # over a spec that never executed a line. For a tool whose entire output is
        # "this pin is green", that is the worst reachable failure, so zero examples
        # gets a failure with its own name.
        if summary["example_count"].to_i.zero?
          return Outcome.new(config: config, status: :failed, diagnosis: :no_examples_ran,
                             detail: excerpt(stdout, stderr), examples: 0, failures: 0)
        end

        # And rspec counts a load error separately from a failure, so a file that
        # raised while being read can still report failure_count 0.
        if summary["errors_outside_of_examples_count"].to_i.positive?
          return Outcome.new(config: config, status: :failed, diagnosis: :spec_load_error,
                             detail: excerpt(stdout, stderr),
                             examples: summary["example_count"], failures: 0)
        end

        Outcome.new(config: config, status: :green, diagnosis: nil, detail: nil,
                    examples: summary["example_count"], failures: 0)
      end

      def arguments_for(config)
        relative = @spec_path.sub("#{@app_root}/", "")
        base = ["bundle", "exec", "rspec", "--format", "json"]

        case config
        when :isolated
          [base + [relative], {}]
        when :hostile
          # A pin that only holds on the capture machine says so here, rather than
          # on someone else's CI.
          [base + ["--seed", "7", relative], { "TZ" => hostile_tz, "LANG" => "C", "LC_ALL" => "C" }]
        when :neighbored
          # The same file twice in one process: accumulated deliveries and leaked
          # globals only show up when something ran before you.
          [base + [relative, relative], {}]
        end
      end

      def hostile_tz
        HOSTILE_TZ_CANDIDATES.find { |zone| zone != @captured_tz } || HOSTILE_TZ_CANDIDATES.first
      end

      # The parent's bundler environment is scrubbed for the same reason the probe
      # scrubs it: pinspec's own Gemfile must not follow it into the app.
      def environment
        Runner::Sandbox::SCRUBBED_ENV
          .merge("RAILS_ENV" => "test", "DISABLE_SPRING" => "1", "TZ" => @captured_tz)
          .merge(@env)
      end

      def parse(stdout)
        json = stdout.to_s.lines.reverse.find { |line| line.strip.start_with?("{") }
        return nil if json.nil?

        parsed  = JSON.parse(json)
        summary = parsed["summary"]
        return nil if summary.nil?

        # The load-error count sits in the summary in modern rspec-core and at the top
        # level in older ones; carry whichever is there so `run` can see it.
        summary.merge(
          "errors_outside_of_examples_count" =>
            summary["errors_outside_of_examples_count"] ||
            parsed["errors_outside_of_examples_count"] || 0
        )
      rescue JSON::ParserError
        nil
      end

      def failure(config, stdout, stderr, summary)
        text = "#{stdout}\n#{stderr}"
        found = DIAGNOSES.find { |pattern, _| text.match?(pattern) }

        Outcome.new(
          config: config,
          status: :failed,
          diagnosis: found ? found.last : :unknown,
          detail: excerpt(stdout, stderr),
          examples: summary && summary["example_count"],
          failures: summary && summary["failure_count"]
        )
      end

      def excerpt(stdout, stderr)
        messages = failed_examples(stdout).map do |example|
          "#{example['full_description']}\n#{example.dig('exception', 'message').to_s.lines.first(6).join}"
        end

        return messages.first(2).join("\n\n") unless messages.empty?

        (stderr.to_s.empty? ? stdout.to_s : stderr.to_s).lines.last(20).join
      end

      def failed_examples(stdout)
        json = stdout.to_s.lines.reverse.find { |line| line.strip.start_with?("{") }
        return [] if json.nil?

        JSON.parse(json)["examples"].to_a.reject { |example| example["status"] == "passed" }
      rescue StandardError
        []
      end
    end
  end
end
