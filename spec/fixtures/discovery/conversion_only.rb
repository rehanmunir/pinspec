# frozen_string_literal: true

# Its whole public surface is `to_a`. Taken from Open Food Network's
# Orders::AvailablePaymentMethodsService, which pinspec refused as having nothing to
# pin because to_a was on the never-a-target list.
class ConversionOnly
  def initialize(order)
    @order = order
  end

  def to_a
    filtered
  end

  private

  def filtered
    @order.payment_methods
  end
end
