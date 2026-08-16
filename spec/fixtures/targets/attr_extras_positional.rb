# frozen_string_literal: true

# Bare symbols are positional arguments, not keywords.
class AttrExtrasPositional
  attr_initialize :account, :params

  def call
    [account, params]
  end
end
