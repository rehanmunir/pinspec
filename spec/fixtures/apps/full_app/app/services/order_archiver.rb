# orders.service_area is NOT NULL with a PostGIS type pinspec does not model, so
# no honest value exists for it.
class OrderArchiver
  def initialize(order)
    @order = order
  end

  def call
    @order.touch
  end
end
