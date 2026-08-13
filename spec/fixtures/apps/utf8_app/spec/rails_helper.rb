# frozen_string_literal: true

# Nettoyage de la base entre les exemples. Les accents ici sont délibérés:
# c'est exactement ce qu'un vrai dépôt contient - "Coopérative de Montréal",
# des prix en €, et des noms comme Zoé.
RSpec.configure do |config|
  config.use_transactional_fixtures = false
end

DatabaseCleaner.strategy = :truncation
