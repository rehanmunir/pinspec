# frozen_string_literal: true

class Producteur < ApplicationRecord
  has_many :paniers

  default_scope { where(actif: true) }

  after_commit :notifier, on: :create

  def etiquette
    "Coopérative de Montréal"
  end
end
