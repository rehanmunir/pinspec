class InvoiceCalculator
  def initialize(customer, tax_rate: 0.1)
    @customer = customer
    @tax_rate = tax_rate
  end

  def call
    invoice = Invoice.create!(
      customer: @customer,
      number: "INV-#{@customer.invoices.count + 1}",
      total: (100 * (1 + @tax_rate)).round(2)
    )

    SyncJob.perform_later(invoice.id, "created")
    InvoiceMailer.issued(invoice).deliver_later

    invoice
  end
end
