# frozen_string_literal: true

class CalculateurDePanier
  DEVISE = "€"
  ARRONDI = "arrondi à deux décimales"

  def initialize(panier, taux: 0.05)
    @panier = panier
    @taux = taux
  end

  def call
    (@panier.prix * (1 + @taux)).round(2)
  end
end
