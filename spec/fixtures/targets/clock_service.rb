# frozen_string_literal: true

class ExpiryChecker
  def initialize(invoice)
    @invoice = invoice
  end

  def call
    return :expired if @invoice.due_at < Time.now
    return :today if @invoice.due_on == Date.today

    return :zoned if @invoice.created_at > Time.zone.now
    return :safe if @invoice.created_at > Time.current

    Time.new(2020, 1, 1)
  end
end

class DefaultClockService
  def call(as_of = Time.now)
    as_of
  end
end
