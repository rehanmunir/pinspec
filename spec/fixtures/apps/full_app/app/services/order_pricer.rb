# Three constructor parameters and two method parameters: the shape that proves
# the --cases budget reaches both lists rather than being spent on the first.
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
