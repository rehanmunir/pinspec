# frozen_string_literal: true

# attr_extras generates the constructor, so there is no `def initialize` to read.
# Shapes taken from chatwoot, where 110 of 386 service files use this.
class AttrExtrasService
  pattr_initialize [:inbox!, :source_ids!, :contact_attributes]

  def perform
    [inbox, source_ids, contact_attributes]
  end
end
