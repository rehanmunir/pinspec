# frozen_string_literal: true

# PINSPEC SPEC SUPPORT. Generated - do not hand-edit; regenerate it.
#
# The spec-host half of spec v0.3 section 4c. Every axis the probe controls is
# controlled here too, by the same rules, so that a snapshot captured in one host
# means the same thing in the other:
#
#   isolation - forced regardless of the suite's own strategy
#   sinks     - adapters forced to :test, cleared, and read per example
#   clock     - the plan's frozen instant, travelled to and back
#   locale    - the plan's locale
#   zone      - the plan's zone, plus a guard on the process TZ, which no spec can
#               set for itself before Rails boots
#
# Ruby 2.6 syntax floor: this runs in the target app's Ruby, not pinspec's.
module PinspecSupport
  # A capture is only comparable if it saw the same world. TZ is the one axis a
  # spec cannot set for itself - the process env is fixed before Rails boots - so
  # it is checked rather than imposed, and named when it is wrong.
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

  # { "table:pk" => "ref" } for the records this spec built, plus the record the
  # target returned under "__returned__".
  #
  # The returned record has to be in the table before the side-effect sinks are
  # read: the commonest side effect is perform_later(the_record_just_created.id),
  # and that id is a sequence value which differs on every run.
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

  # Runs the block with empty sinks and returns what it enqueued, normalized.
  #
  # Block-scoped on purpose: a factory's after(:create) enqueues too, and an
  # assertion that counted setup's jobs would pass for the wrong reason. This is
  # the same "clear after setup, before the target" point the probe makes.
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

  # Forced for pinspec examples only, so that a suite whose own adapter is :inline
  # - which executes jobs instead of enqueuing them, and would make every job pin
  # see nothing - cannot silently empty the sinks.
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
