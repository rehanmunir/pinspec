# frozen_string_literal: true

class BatchRunner
  def each_invoice
    Invoice.find_each { |invoice| yield invoice }
  end

  def with_logging(&block)
    block.call
  end

  def plain
    :ok
  end
end
