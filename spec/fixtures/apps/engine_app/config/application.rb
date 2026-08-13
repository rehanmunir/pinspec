# frozen_string_literal: true

# An app built on an engine, which is what most legacy commerce Rails is: the
# engine's models live behind a table_name_prefix, so a parameter named `order`
# names a model whose table is `shop_orders`.
module Storefront
  class Application < Rails::Application
    config.i18n.default_locale = :en
    config.time_zone = "UTC"
  end
end
