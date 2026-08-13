# frozen_string_literal: true

# The headline shape: a zero-argument #call with its dependency in the
# constructor, on a model whose table lives behind an engine prefix.
class OrderSummary
  def initialize(order)
    @order = order
  end

  def call
    { total: @order.total }
  end
end
