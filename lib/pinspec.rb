# frozen_string_literal: true

require "zeitwerk"

module Pinspec
end

require_relative "pinspec/version"
require_relative "pinspec/errors"
require_relative "pinspec/types"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect("cli" => "CLI")
loader.ignore("#{__dir__}/pinspec/version.rb")
loader.ignore("#{__dir__}/pinspec/errors.rb")
loader.ignore("#{__dir__}/pinspec/types.rb")
loader.setup
