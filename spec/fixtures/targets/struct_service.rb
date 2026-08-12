# frozen_string_literal: true

class LineTotal < Struct.new(:quantity, :unit_price)
  def call
    quantity * unit_price
  end
end
