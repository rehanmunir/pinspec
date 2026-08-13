class Invoice < ApplicationRecord
  belongs_to :customer
  has_many :line_items

  def subtotal
    line_items.sum { |item| item.quantity * item.unit_price }
  end
end
