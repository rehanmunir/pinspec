# frozen_string_literal: true

FactoryBot.define do
  factory :producteur do
    nom { "Coopérative de Montréal" }
    ville { "Montréal" }
  end

  factory :panier do
    producteur
    prix { 12.50 }
  end
end
