# frozen_string_literal: true

module Storefront
  class Application < Rails::Application
    config.i18n.default_locale = :en
    config.time_zone = "UTC"
  end
end
