# frozen_string_literal: true

# `distributor` names nothing this application has: no distributors table, no
# Distributor model, no :distributor factory. pinspec must refuse rather than pass
# nil, because the target would raise on nil and that error would be pinned as
# though the application produced it.
class RoutePlanner
  def initialize(distributor)
    @distributor = distributor
  end

  def call
    @distributor.warehouses.count
  end
end
