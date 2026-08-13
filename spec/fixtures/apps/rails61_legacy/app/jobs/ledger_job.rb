class LedgerJob < ApplicationJob
  queue_as :ledger

  def perform(order_id, reason)
    [order_id, reason]
  end
end
