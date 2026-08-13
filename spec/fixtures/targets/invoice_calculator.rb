# frozen_string_literal: true

class InvoiceCalculator
  def initialize(invoice, tax_engine: TaxEngine.new, rounding: :up)
    @invoice = invoice
    @tax_engine = tax_engine
    @rounding = rounding
  end

  def call
    total = @invoice.line_items.sum(&:amount)
    Invoice.create!(customer: @invoice.customer, total: total + tax)
  end

  private

  def tax
    @tax_engine.rate_for(@invoice)
  end
end
