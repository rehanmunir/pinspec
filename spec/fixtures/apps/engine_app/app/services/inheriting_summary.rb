# frozen_string_literal: true

# Defines no #initialize. The constructor comes from a superclass in another file,
# which pinspec has to go and read.
class InheritingSummary < ApplicationService
  def call
    { total: @order.total }
  end
end
