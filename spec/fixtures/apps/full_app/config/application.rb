module FullApp
  class Application < Rails::Application
    config.load_defaults 7.1
    config.i18n.default_locale = :de
    config.time_zone = "Berlin"
    config.active_storage.variant_processor = :vips
  end
end
