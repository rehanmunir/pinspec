require_relative "boot"

require "active_record/railtie"
require "active_job/railtie"
require "action_mailer/railtie"

# What every real Rails app does, and without it a gem's railtie never loads -
# so factory_bot registers no factories.
Bundler.require(*Rails.groups)

module Rails71Basic
  class Application < Rails::Application
    config.load_defaults 7.0
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
    config.active_support.to_time_preserves_timezone = :zone
  end
end
