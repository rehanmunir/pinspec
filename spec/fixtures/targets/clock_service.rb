# frozen_string_literal: true

class ExpiryChecker
  def initialize(invoice)
    @invoice = invoice
  end

  def call
    return :expired if @invoice.due_at < Time.now
    return :today if @invoice.due_on == Date.today

    # Zone-aware: these honour the plan's :set_zone step, so they are not
    # clock sites.
    return :zoned if @invoice.created_at > Time.zone.now
    return :safe if @invoice.created_at > Time.current

    # A fixed instant, not a clock read.
    Time.new(2020, 1, 1)
  end
end

# A clock read in a parameter default still runs when pinspec omits the argument.
class DefaultClockService
  def call(as_of = Time.now)
    as_of
  end
end
