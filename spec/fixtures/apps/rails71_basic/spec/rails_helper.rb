require "spec_helper"

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers

  # Deliberately NOT the app's defaults. A pin captured under the app's own locale
  # and zone must force them back, or it silently compares values from a different
  # world - which is the whole point of spec section 4c's locale and zone axes.
  config.before(:each) do
    I18n.locale = :fr
    Time.zone = "Asia/Tokyo"
  end
end
