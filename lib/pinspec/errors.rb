# frozen_string_literal: true

module Pinspec
  # Exit-code taxonomy, spec v0.3 §5.1. The codes are part of the CLI contract:
  # they are how a script tells "this target takes a block" from "this target
  # doesn't exist", so they are asserted in specs, not just documented.
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

  # 1 — generic. A file that isn't valid Ruby is a user problem, not a missing target.
  class UnparsableSource < Error
    self.exit_code = 1
  end

  # 2 — no such method. Carries a redirect when the miss is explainable
  # (delegation, method_missing) so the error is a lead, not a dead end.
  class TargetNotFound < Error
    self.exit_code = 2
  end

  # 3 — the name resolves to more than one definition in the file.
  class AmbiguousTarget < Error
    self.exit_code = 3
  end

  # 4 — blocks cannot cross the probe/spec JSON boundary. Clean refusal.
  class BlockRequired < Error
    self.exit_code = 4
  end

  # 5 — we understood the target and cannot build a world for it. `reason` is the
  # machine-readable half; the message names the specific attribute/constant/class.
  class UnresolvableSetup < Error
    self.exit_code = 5

    REASONS = %i[
      association_cycle
      attachment
      opaque_constructor
      unknown_column_type
      apartment
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

  # 6 — db/structure.sql instead of db/schema.rb.
  class SchemaFormatUnsupported < Error
    self.exit_code = 6
  end

  # 7 — the app didn't boot, or the probe died.
  class ProbeFailure < Error
    self.exit_code = 7
  end

  # 8 — every case was unstable or quarantined. Never emit a silent empty spec.
  class NothingStableToPin < Error
    self.exit_code = 8
  end

  # 9 — emitted, but a verification config wasn't green.
  class VerifyFailed < Error
    self.exit_code = 9
  end

  # 10 — target app below the Rails 6.0 floor (spec v0.3 §0.1).
  class UnsupportedRailsVersion < Error
    self.exit_code = 10
  end

  # 11 — refused to run outside RAILS_ENV=test without confirmation.
  class EnvironmentRefused < Error
    self.exit_code = 11
  end

  # 12 — our bug. Always dumped verbosely, never blamed on the user.
  class PinspecInternalError < Error
    self.exit_code = 12
  end
end
