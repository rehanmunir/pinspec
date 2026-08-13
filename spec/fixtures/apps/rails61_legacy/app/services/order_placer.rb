# No factories in this app, so the plan builds every record from the schema - the
# path that until now had only been tested statically.
class OrderPlacer
  def initialize(shop, status: "pending")
    @shop = shop
    @status = status
  end

  def call
    Order.create!(shop: @shop, reference: "REF-#{@shop.orders.count + 1}", status: @status)
  end
end
