# frozen_string_literal: true

# A base class in its own file, the way real applications write one. Its
# constructor is the effective constructor of everything below it.
class ApplicationService
  def initialize(order, actor: nil)
    @order = order
    @actor = actor
  end
end
