# frozen_string_literal: true

class SendInvoice
  include Interactor

  delegate :invoice, :recipient, to: :context

  def call
    InvoiceMailer.with(invoice: invoice, to: recipient).notification.deliver_later
  end
end
