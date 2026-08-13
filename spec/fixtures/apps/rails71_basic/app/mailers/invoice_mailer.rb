class InvoiceMailer < ApplicationMailer
  def issued(invoice)
    mail(to: invoice.customer.email, subject: "Invoice #{invoice.number}", body: "Thanks")
  end
end
