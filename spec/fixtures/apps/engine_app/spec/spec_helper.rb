# frozen_string_literal: true

# This suite has spec_helper and NO rails_helper, which is the convention Open Food
# Network uses. A pin that hardcodes `require "rails_helper"` cannot be loaded here.
RSpec.configure do |config|
  config.use_transactional_fixtures = true
end
