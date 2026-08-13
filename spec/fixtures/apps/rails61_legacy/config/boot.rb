ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

# Rails 6.1 relies on `logger` being loaded implicitly, which newer Rubies no
# longer do - without this it dies in LoggerThreadSafeLevel before it starts.
# Exactly the kind of thing a legacy app carries.
require "logger"
require "bundler/setup"
