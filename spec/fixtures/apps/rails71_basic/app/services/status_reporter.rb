class StatusReporter
  def initialize(invoice)
    @invoice = invoice
  end

  def call(uppercase: false)
    raise ArgumentError, "no status" if @invoice.status.nil?

    uppercase ? @invoice.status.upcase : @invoice.status
  end
end
