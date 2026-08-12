class Order < ApplicationRecord
  acts_as_tenant :company
  has_paper_trail
  acts_as_paranoid
  has_one_attached :invoice_pdf

  default_scope { where(archived: false) }

  after_commit :sync_to_warehouse, on: :create
  after_update_commit :notify_customer

  def sync_to_warehouse
    WarehouseSyncJob.perform_later(self)
  end
end
