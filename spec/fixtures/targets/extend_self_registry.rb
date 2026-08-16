# frozen_string_literal: true

# The other spelling of the same thing.
module ExtendSelfRegistry
  extend self

  def supported?(metric)
    metric.to_s.start_with?("count")
  end
end
