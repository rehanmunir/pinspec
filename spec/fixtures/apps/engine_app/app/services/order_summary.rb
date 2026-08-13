# frozen_string_literal: true

class OrderSummary
  def initialize(order)
    @order = order
  end

  def call
    { total: @order.total }
  end
end
