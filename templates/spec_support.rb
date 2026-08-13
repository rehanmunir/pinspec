# frozen_string_literal: true

module PinspecSupport
  def pinspec_guard_env!(expected)
    actual = ENV["TZ"].to_s
    return if expected.to_s.empty?
    return if actual == expected.to_s

    raise <<~MESSAGE
      pinspec: this pin was captured with TZ=#{expected}, but this process has
      TZ=#{actual.empty? ? '(unset)' : actual}.

      The target reads the process clock (see the warning in this spec's header),
      so the pinned values are only valid under the capture's timezone. Re-run with
      TZ=#{expected}, or re-capture under this one.
    MESSAGE
  end

  def pinspec_refs(records, result = nil)
    refs = {}

    records.each do |name, record|
      next if record.nil?

      refs["#{record.class.table_name}:#{record.id}"] = name.to_s
    end

    if defined?(ActiveRecord::Base) && result.is_a?(ActiveRecord::Base) && !result.id.nil?
      refs["#{result.class.table_name}:#{result.id}"] = "__returned__"
    end

    refs
  end

  def pinspec_jobs_from(refs_for, fk_map)
    pinspec_clear_sinks
    result = yield
    refs = refs_for.call(result)

    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.map do |job|
      {
        "job" => job[:job].to_s,
        "queue" => job[:queue].to_s,
        "args" => PinspecSerializer.normalize(job[:args], refs: refs, fk_map: fk_map)
      }
    end

    [result, jobs]
  end

  def pinspec_deliveries
    ActionMailer::Base.deliveries.map do |mail|
      { "to" => Array(mail.to).join(","), "subject" => mail.subject.to_s }
    end
  end

  def pinspec_clear_sinks
    if defined?(ActiveJob::Base) && ActiveJob::Base.queue_adapter.respond_to?(:enqueued_jobs)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      ActiveJob::Base.queue_adapter.performed_jobs.clear
    end

    ActionMailer::Base.deliveries.clear if defined?(ActionMailer::Base)
  end
end

RSpec.configure do |config|
  config.include PinspecSupport, pinspec: true

  config.around(:each, pinspec: true) do |example|
    previous = defined?(ActiveJob::Base) ? ActiveJob::Base.queue_adapter : nil
    ActiveJob::Base.queue_adapter = :test if defined?(ActiveJob::Base)

    if defined?(ActionMailer::Base)
      ActionMailer::Base.delivery_method = :test
      ActionMailer::Base.perform_deliveries = true
    end

    example.run

    ActiveJob::Base.queue_adapter = previous if previous
  end
end
