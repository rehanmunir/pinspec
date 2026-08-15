# frozen_string_literal: true

require "json"
require "open3"

module Pinspec
  module Verify
    class Verifier
      CONFIGS = %i[isolated hostile neighbored].freeze

      HOSTILE_TZ_CANDIDATES = ["Etc/GMT+8", "Etc/GMT-6"].freeze

      Outcome = Data.define(:config, :status, :diagnosis, :detail, :examples, :failures) do
        def green?
          status == :green
        end

        def to_s
          green? ? "#{config}: green (#{examples} examples)" : "#{config}: #{status} (#{diagnosis})"
        end
      end

      DIAGNOSES = [
        [/WebMock::NetConnectNotAllowedError|VCR::Errors/, :unpinnable_http],
        [/captured with TZ=/, :tz_dependent],
        [/uninitialized constant PinspecSerializer|PinspecSerializer.*NoMethodError/, :pinspec_internal],
        [/RecordNotUnique|has already been taken/, :seed_collision],
        [/DatabaseCleaner/, :db_cleaner_strategy],
        [/cannot load such file -- (rails_helper|spec_helper)/, :spec_helper_missing],
        [/LoadError|cannot load such file/, :rails_helper_variance]
      ].freeze

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

        if summary["example_count"].to_i.zero?
          return Outcome.new(config: config, status: :failed, diagnosis: :no_examples_ran,
                             detail: excerpt(stdout, stderr), examples: 0, failures: 0)
        end

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
          [base + ["--seed", "7", relative], { "TZ" => hostile_tz, "LANG" => "C", "LC_ALL" => "C" }]
        when :neighbored
          [base + [relative, relative], {}]
        end
      end

      def hostile_tz
        HOSTILE_TZ_CANDIDATES.find { |zone| zone != @captured_tz } || HOSTILE_TZ_CANDIDATES.first
      end

      def environment
        Runner::Runtime.for(@app_root).env
                       .merge("RAILS_ENV" => "test", "DISABLE_SPRING" => "1", "TZ" => @captured_tz)
                       .merge(@env)
      end

      def parse(stdout)
        json = stdout.to_s.lines.reverse.find { |line| line.strip.start_with?("{") }
        return nil if json.nil?

        parsed  = JSON.parse(json)
        summary = parsed["summary"]
        return nil if summary.nil?

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
