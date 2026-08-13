class OrderPlacer
  def initialize(shop, status: "pending")
    @shop = shop
    @status = status
  end

  def call
    Order.create!(shop: @shop, reference: "REF-#{@shop.orders.count + 1}", status: @status)
  end
end
