class InvoiceCalculator
  def initialize(invoice, tax_rate: 0.08)
    @invoice = invoice
    @tax_rate = tax_rate
  end

  def call
    Invoice.create!(customer: @invoice.customer, total: @invoice.total * (1 + @tax_rate))
  end
end
