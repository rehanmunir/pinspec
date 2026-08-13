RSpec.configure do |config|
  config.use_transactional_fixtures = false

  DatabaseCleaner.strategy = :transaction

  config.before(:each, js: true) { DatabaseCleaner.strategy = :truncation }

  config.before(:each) { ActiveJob::Base.queue_adapter = :inline }
end
