# frozen_string_literal: true

module Pinspec
  class Batch
    SKIP_PATTERNS = [%r{/concerns/}, %r{_spec\.rb\z}, %r{/spec/}, %r{/test/}].freeze

    Outcome = Data.define(:file, :target, :status, :detail, :pinned, :spec_path) do
      def pinned?
        status == :pinned
      end

      def refused?
        status == :refused
      end
    end

    Report = Data.define(:outcomes) do
      def pinned
        outcomes.select(&:pinned?)
      end

      def refused
        outcomes.select(&:refused?)
      end

      def failed
        outcomes.reject { |outcome| outcome.pinned? || outcome.refused? }
      end

      def anything_pinned?
        !pinned.empty?
      end
    end

    # Patterns match the path RELATIVE to the directory being pinned. Matching the
    # absolute path means an app that happens to live under a directory called
    # `spec` has every one of its files skipped.
    def self.targets_in(path)
      return [path] if File.file?(path)

      root = File.expand_path(path)

      Dir.glob(File.join(root, "**", "*.rb")).reject do |file|
        relative = file.delete_prefix("#{root}/")

        SKIP_PATTERNS.any? { |pattern| "/#{relative}".match?(pattern) }
      end.sort
    end

    def initialize(files, &pin)
      @files = files
      @pin = pin
    end

    # A refusal is information, not a stop: one target that takes a block must not
    # end a run over a directory of forty.
    def run
      Report.new(outcomes: @files.map { |file| attempt(file) })
    end

    private

    def attempt(file)
      @pin.call(file)
    rescue UnresolvableSetup, BlockRequired, AmbiguousTarget, TargetNotFound,
           NothingStableToPin, UnsupportedRailsVersion => e
      Outcome.new(file: file, target: nil, status: :refused, detail: reason_for(e),
                  pinned: 0, spec_path: nil)
    rescue VerifyFailed, ProbeFailure => e
      Outcome.new(file: file, target: nil, status: :failed, detail: e.message.lines.first.to_s.strip,
                  pinned: 0, spec_path: nil)
    end

    def reason_for(error)
      return "#{error.class.name.split('::').last}(#{error.reason})" if error.respond_to?(:reason)

      error.class.name.split("::").last
    end
  end
end
