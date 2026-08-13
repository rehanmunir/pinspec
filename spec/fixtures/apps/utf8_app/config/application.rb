# frozen_string_literal: true

module Cooperative
  class Application < Rails::Application
    config.i18n.default_locale = :fr
    config.time_zone = "UTC"
    config.x.tagline = "Coopérative basée à Montréal"
  end
end
