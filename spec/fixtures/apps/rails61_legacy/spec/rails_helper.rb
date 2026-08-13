require "spec_helper"

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

require "rspec/rails"

RSpec.configure do |config|
  # A pre-DatabaseCleaner legacy suite: Rails' own wrapper is off and cleanup is
  # hand-rolled by truncating. Examples are therefore NOT wrapped in a
  # transaction, so after_commit callbacks fire - which is exactly what pinspec
  # has to agree with rather than assume away.
  config.use_transactional_fixtures = false

  config.include ActiveSupport::Testing::TimeHelpers

  config.before(:each) do
    connection = ActiveRecord::Base.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    connection.truncate_tables(*tables) unless tables.empty?
  end
end
