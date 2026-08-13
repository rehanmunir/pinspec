class StatementBuilder
  def initialize(customer)
    @customer = customer
  end

  def call
    @customer
  end
end
