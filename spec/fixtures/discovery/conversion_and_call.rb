# frozen_string_literal: true

# A conversion method must not outrank a real entry point.
class ConversionAndCall
  def call
    :the_answer
  end

  def to_a
    [call]
  end
end
