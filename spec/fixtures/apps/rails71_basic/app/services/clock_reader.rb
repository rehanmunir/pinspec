# The clock axis, negative half: this target reads the PROCESS clock, which
# Time.zone does not govern. pinspec must detect it, warn in the pin's header, and
# guard - so that the hostile verify configuration fails loudly rather than
# letting a timezone-dependent pin pass for the wrong reason.
class ClockReader
  def initialize(invoice)
    @invoice = invoice
  end

  def call
    Time.now.year
  end
end
