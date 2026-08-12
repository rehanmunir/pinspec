# frozen_string_literal: true

class BaseCalculator
  def initialize(invoice, precision: 2)
    @invoice = invoice
    @precision = precision
  end
end

class ShippingCalculator < BaseCalculator
  def call
    (@invoice.weight * 0.5).round(@precision)
  end
end

class PlainObject
  def call
    :ok
  end
end
