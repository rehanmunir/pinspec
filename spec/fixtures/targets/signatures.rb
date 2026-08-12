# frozen_string_literal: true

class SplatService
  def call(a, b = 2, *rest, c, k:, j: 3, **opts)
    [a, b, rest, c, k, j, opts]
  end
end

class EndlessService
  def call(multiplier) = multiplier * 2
end

module Nested
  module Deeply
    class Worker
      def initialize(order)
        @order = order
      end

      def call
        @order
      end
    end
  end
end
