# frozen_string_literal: true

module Pinspec
  class Error < StandardError
    class << self
      attr_writer :exit_code

      def exit_code
        @exit_code || 1
      end
    end

    def exit_code
      self.class.exit_code
    end
  end

  class UnparsableSource < Error
    self.exit_code = 1
  end

  class TargetNotFound < Error
    self.exit_code = 2
  end

  class AmbiguousTarget < Error
    self.exit_code = 3
  end

  class BlockRequired < Error
    self.exit_code = 4
  end

  class UnresolvableSetup < Error
    self.exit_code = 5

    REASONS = %i[
      association_cycle
      attachment
      opaque_constructor
      unknown_column_type
      apartment
      unresolvable_parameter
    ].freeze

    attr_reader :reason

    def initialize(reason, message = nil)
      unless REASONS.include?(reason)
        raise ArgumentError, "unknown UnresolvableSetup reason: #{reason.inspect}"
      end

      @reason = reason
      super(message || reason.to_s.tr("_", " "))
    end
  end

  class SchemaFormatUnsupported < Error
    self.exit_code = 6
  end

  class ProbeFailure < Error
    self.exit_code = 7
  end

  class NothingStableToPin < Error
    self.exit_code = 8
  end

  class VerifyFailed < Error
    self.exit_code = 9
  end

  class UnsupportedRailsVersion < Error
    self.exit_code = 10
  end

  class EnvironmentRefused < Error
    self.exit_code = 11
  end

  class PinspecInternalError < Error
    self.exit_code = 12
  end
end
