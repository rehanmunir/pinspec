# frozen_string_literal: true

module Billing
  class Reconciler
    class << self
      def sweep(period)
        new.perform(period)
      end
    end

    def self.call(invoice_id, dry_run: false)
      new.perform(invoice_id, dry_run: dry_run)
    end

    def perform(*args)
      args
    end
  end
end
