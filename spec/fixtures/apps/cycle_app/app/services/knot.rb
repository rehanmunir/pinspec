class Knot
  def initialize(chicken)
    @chicken = chicken
  end

  def call
    @chicken
  end
end

class SelfKnot
  def initialize(node)
    @node = node
  end

  def call
    @node
  end
end
