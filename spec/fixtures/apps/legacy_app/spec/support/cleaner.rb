RSpec.configure do |config|
  # Rails' own wrapper is off precisely so DatabaseCleaner can wrap instead. This
  # suite IS transacted, and reading use_transactional_fixtures alone would say
  # otherwise.
  config.use_transactional_fixtures = false

  DatabaseCleaner.strategy = :transaction

  config.before(:each, js: true) { DatabaseCleaner.strategy = :truncation }

  config.before(:each) { ActiveJob::Base.queue_adapter = :inline }
end
