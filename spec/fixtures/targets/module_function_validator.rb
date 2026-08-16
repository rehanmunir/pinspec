# frozen_string_literal: true

# A module that answers its own methods. Calling .new on it raised
# "undefined method 'new' for module ..." inside the probe.
module ModuleFunctionValidator
  module_function

  def valid?(timestamp)
    !timestamp.nil?
  end
end
