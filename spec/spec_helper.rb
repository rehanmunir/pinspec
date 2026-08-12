# frozen_string_literal: true

require "pinspec"

module FixtureHelpers
  FIXTURE_DIR = File.expand_path("fixtures/targets", __dir__)

  def fixture(name)
    File.join(FIXTURE_DIR, name)
  end

  def parse(name, method)
    Pinspec::Analyzer::TargetParser.parse(fixture(name), method)
  end

  # The acceptance criterion is that source_range is exact to the def...end span,
  # which is worth asserting against the text rather than against line numbers
  # that shift every time a fixture is edited.
  def source_span(name, range)
    lines = File.readlines(fixture(name))
    lines[(range.first - 1)..(range.last - 1)].join
  end

  def param(params, name)
    params.find { |p| p.name == name }
  end
end

RSpec.configure do |config|
  config.include FixtureHelpers
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end
