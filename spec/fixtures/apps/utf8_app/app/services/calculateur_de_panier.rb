# frozen_string_literal: true

# Calcule le prix d'un panier, taxes comprises.
class CalculateurDePanier
  def initialize(panier, taux: 0.05)
    @panier = panier
    @taux = taux
  end

  # Retourne le prix arrondi - la devise est l'€.
  def call
    (@panier.prix * (1 + @taux)).round(2)
  end
end
