class OrderPricer
  def initialize(company, discount: 0.1, currency: "USD", rounding: :up)
    @company = company
    @discount = discount
    @currency = currency
    @rounding = rounding
  end

  def call(quantity, express: false)
    [quantity, express]
  end
end
