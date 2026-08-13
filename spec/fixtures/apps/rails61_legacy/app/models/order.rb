class Order < ApplicationRecord
  belongs_to :shop

  after_commit :announce, on: :create

  def announce
    LedgerJob.perform_later(id, "committed")
  end
end
