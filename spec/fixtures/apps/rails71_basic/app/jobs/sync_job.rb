class SyncJob < ApplicationJob
  queue_as :sync

  def perform(invoice_id, reason)
    [invoice_id, reason]
  end
end
