# frozen_string_literal: true

class TaxComputer
  extend Dry::Initializer

  param :invoice
  option :rate, default: -> { 0.0825 }
  option :jurisdiction

  def call
    (invoice.total * rate).round(2)
  end
end
