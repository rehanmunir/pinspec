# frozen_string_literal: true

class Invoice < ApplicationRecord
  has_many :line_items

  def total
    line_items.sum(&:amount)
  end
end

class LineItem < ActiveRecord::Base
  def amount
    quantity * unit_price
  end
end
