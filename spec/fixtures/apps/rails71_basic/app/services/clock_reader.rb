class ClockReader
  def initialize(invoice)
    @invoice = invoice
  end

  def call
    Time.now.year
  end
end
