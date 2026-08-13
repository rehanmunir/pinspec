class OrderArchiver
  def initialize(order)
    @order = order
  end

  def call
    @order.touch
  end
end
