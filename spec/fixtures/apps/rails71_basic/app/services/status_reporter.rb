# A plain scalar return, and a raise on one branch: raises are pins too.
class StatusReporter
  def initialize(invoice)
    @invoice = invoice
  end

  def call(uppercase: false)
    raise ArgumentError, "no status" if @invoice.status.nil?

    uppercase ? @invoice.status.upcase : @invoice.status
  end
end
