class Order < ApplicationRecord
  belongs_to :shop

  # The crux of matrix row 17. Under a transaction that gets rolled back this
  # NEVER fires; under truncation it DOES. Both hosts have to agree about which,
  # which is why isolation is a property of the plan rather than an assumption.
  after_commit :announce, on: :create

  def announce
    LedgerJob.perform_later(id, "committed")
  end
end
