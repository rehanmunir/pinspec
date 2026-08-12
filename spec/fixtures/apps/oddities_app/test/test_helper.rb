require_relative "../config/environment"

class ActiveSupport::TestCase
  # No DatabaseCleaner anywhere: nothing wraps these examples at all.
  self.use_transactional_fixtures = false
end
