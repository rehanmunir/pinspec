# frozen_string_literal: true

class RoutePlanner
  def initialize(distributor)
    @distributor = distributor
  end

  def call
    @distributor.warehouses.count
  end
end
