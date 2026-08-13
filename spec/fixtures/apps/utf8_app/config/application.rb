# frozen_string_literal: true

# Une application française: the comments below carry the accents that a real
# internationalised codebase has in it, which is the whole point of this fixture.
module Cooperative
  class Application < Rails::Application
    # Locale par défaut - la coopérative est basée à Montréal.
    config.i18n.default_locale = :fr
    config.time_zone = "UTC"
  end
end
