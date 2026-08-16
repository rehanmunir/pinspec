# frozen_string_literal: true

# pinspec factory builder - generated. Do not hand-edit: re-run pinspec.
module PinspecFactory
  MAX_ATTEMPTS = 8

  # factory_bot sequences are process-global and monotonic, so a pin whose world uses
  # one is only reproducible while nothing else in the process built that factory
  # first. Running the same pin twice in one process produced INV-1 then INV-2 and the
  # second run failed against its own snapshot. Both hosts rewind before every case,
  # so a case always sees the same sequence values.
  def self.reset_sequences!
    mod = defined?(FactoryBot) ? FactoryBot : (defined?(FactoryGirl) ? FactoryGirl : nil)
    return unless mod.respond_to?(:rewind_sequences)

    mod.rewind_sequences
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

        return record
      rescue StandardError => e
        raise unless retryable?(e)

        last_error = e
      end
    end

    raise last_error
  end

  def self.retryable?(error)
    defined?(ActiveRecord::RecordInvalid) && error.is_a?(ActiveRecord::RecordInvalid)
  end

end
