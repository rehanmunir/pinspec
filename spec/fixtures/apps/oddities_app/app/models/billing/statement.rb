module Billing
  class Statement < ApplicationRecord
    after_commit :push_to_ledger
  end
end
