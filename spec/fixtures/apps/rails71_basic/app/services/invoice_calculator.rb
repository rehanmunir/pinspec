# Matrix row 30, and the reason this fixture exists: a zero-argument #call whose
# dependencies are in the constructor, which RETURNS A RECORD IT JUST CREATED
# carrying a foreign key - plus a job and a mail, so side-effect capture has
# something to capture.
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
