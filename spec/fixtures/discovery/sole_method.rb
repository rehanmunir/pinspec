# frozen_string_literal: true

class Formatter
  def format_amount(amount)
    amount.round(2)
  end

  private

  def rounding
    2
  end
end
