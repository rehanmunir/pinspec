# frozen_string_literal: true

# Un producteur de la coopérative. Le commentaire est accentué exprès.
class Producteur < ApplicationRecord
  has_many :paniers

  default_scope { where(actif: true) }

  after_commit :notifier, on: :create

  # "Coopérative de Montréal" - a UTF-8 string literal in app code.
  def etiquette
    "Coopérative de Montréal"
  end
end
