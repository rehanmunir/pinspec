# frozen_string_literal: true

FIXTURE_LABEL = "Coopérative de Montréal"
FIXTURE_CURRENCY = "€"

RSpec.configure do |config|
  config.use_transactional_fixtures = false
  config.filter_run_excluding label: "Zoé"
end

DatabaseCleaner.strategy = :truncation
