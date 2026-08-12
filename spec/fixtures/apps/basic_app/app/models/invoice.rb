class Invoice < ApplicationRecord
  belongs_to :customer
  has_many :line_items

  def total
    line_items.sum(&:amount)
  end
end
