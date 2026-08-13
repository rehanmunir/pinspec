# frozen_string_literal: true

class Ancien < ApplicationRecord
  LEGACY_LABEL = "café ancien"

  default_scope { where(actif: true) }
end
