# frozen_string_literal: true

require_relative "lib/pinspec/version"

Gem::Specification.new do |spec|
  spec.name        = "pinspec"
  spec.version     = Pinspec::VERSION
  spec.authors     = ["Rehan Munir"]
  spec.email       = ["rehanir.munir@gmail.com"]

  spec.summary     = "Characterization-test harness for legacy Rails codebases."
  spec.description = <<~DESC
    Point pinspec at a Rails service object or model method and it works out how to
    invoke it, executes it against your test database, and emits an idiomatic RSpec
    file that freezes the current behavior - then verifies that file runs green in
    your app's own test environment.
  DESC
  spec.homepage = "https://github.com/rehanmunir/pinspec"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"]    = spec.homepage
  spec.metadata["changelog_uri"]      = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]    = "#{spec.homepage}/issues"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "templates/**/*",
    "exe/*",
    "*.md",
    "LICENSE*"
  ]
  spec.bindir        = "exe"
  spec.executables   = ["pinspec"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2"
  spec.add_dependency "thor", "~> 1.2"
  spec.add_dependency "zeitwerk", "~> 2.6"
end
