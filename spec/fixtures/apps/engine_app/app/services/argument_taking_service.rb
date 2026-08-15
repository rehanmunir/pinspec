# frozen_string_literal: true

# No constructor anywhere in the chain: dependencies arrive as method arguments.
# This is the mastodon shape, and 88% of that codebase's services look like it.
class ArgumentTakingService < BaseHandler
  def call(order)
    order.total
  end
end
