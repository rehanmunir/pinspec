# frozen_string_literal: true

# pinspec factory builder - generated. Do not hand-edit: re-run pinspec.
module PinspecFactory
  MAX_ATTEMPTS = 8

  def self.attempts
    @attempts ||= {}
  end

  def self.reset_attempts!
    @attempts = {}
  end

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

  def self.fragile
    attempts.select { |_name, count| count > 1 }
  end
end
