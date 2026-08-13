require_relative "boot"

require "active_record/railtie"
require "active_job/railtie"

Bundler.require(*Rails.groups)

module Rails61Legacy
  class Application < Rails::Application
    config.load_defaults 6.1
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
  end
end
