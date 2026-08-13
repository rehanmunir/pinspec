# frozen_string_literal: true

# pinspec factory builder - generated. Do not hand-edit: re-run pinspec.
#
# ONE source, embedded verbatim in the probe and written beside the emitted spec,
# for the same reason the serializer is (spec v0.3 section 4c): both hosts must
# build the same world, and two copies of this loop would be two chances to drift.
#
# Why a retry loop exists at all. A real application's factories are frequently
# NOT deterministic - Open Food Network's `:user` factory draws an email from
# FFaker, and roughly one in three is rejected by the app's own validation. Its own
# suite tolerates that because each run draws different values and mostly gets
# lucky. pinspec cannot: it pins `srand(42)` so that a plan is reproducible, and a
# fixed seed turns "usually passes" into "always fails". On OFN the first two
# attempts raise and the third succeeds, every single time.
#
# Retrying does not cost determinism, which is the point that makes this sound:
# both hosts start from the same seed and run the same loop, so both consume the
# same random values, fail on the same attempts, and end up with the same record.
# The loop is replayable precisely BECAUSE the seed is fixed.
#
# Held to a Ruby 2.6 syntax floor: this runs in the target app's Ruby, not
# pinspec's.
module PinspecFactory
  # Bounded. A factory that fails this many times in a row is not unlucky, it is
  # broken, and the error is then reported rather than retried into a timeout.
  MAX_ATTEMPTS = 8

  # Recorded so a report can say the factory is seed-fragile instead of leaving
  # someone to wonder why a build took three goes. {factory_name => attempts}.
  def self.attempts
    @attempts ||= {}
  end

  def self.reset_attempts!
    @attempts = {}
  end

  # Whichever DSL the app actually bundles. Detected at runtime rather than baked
  # in, because the emitted spec and the probe are read by the same two gems under
  # two different names and the app is the authority on which it has.
  def self.default_module
    return FactoryBot if defined?(FactoryBot)
    return FactoryGirl if defined?(FactoryGirl)

    raise "pinspec: the plan uses factories but neither FactoryBot nor FactoryGirl is loaded"
  end

  def self.create(name, attrs = {}, factory_module = nil)
    factory_module ||= default_module
    last_error = nil

    1.upto(MAX_ATTEMPTS) do |attempt|
      begin
        record = if attrs.nil? || attrs.empty?
                   factory_module.create(name.to_sym)
                 else
                   factory_module.create(name.to_sym, attrs)
                 end

        attempts[name.to_s] = attempt
        return record
      rescue StandardError => e
        # Only a validation failure is worth another draw: it is the signature of a
        # random attribute the app rejects. A NameError or a missing factory will
        # fail identically every time, so retrying it just hides the real message.
        raise unless retryable?(e)

        last_error = e
      end
    end

    attempts[name.to_s] = MAX_ATTEMPTS
    raise last_error
  end

  def self.retryable?(error)
    defined?(ActiveRecord::RecordInvalid) && error.is_a?(ActiveRecord::RecordInvalid)
  end

  # Factories that needed more than one attempt, for the pin's header and the
  # client report. A seed-fragile factory is a finding about the application, not
  # noise to swallow.
  def self.fragile
    attempts.select { |_name, count| count > 1 }
  end
end
