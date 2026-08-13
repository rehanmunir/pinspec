require_relative "boot"

require "active_record/railtie"
require "active_job/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

module Rails71Basic
  class Application < Rails::Application
    config.load_defaults 7.0
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
    config.active_support.to_time_preserves_timezone = :zone
  end
end
