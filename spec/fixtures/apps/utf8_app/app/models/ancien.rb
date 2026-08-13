# frozen_string_literal: true
#
# A file with a byte that is not valid UTF-8 at all: é written as Latin-1,
# which is what a comment edited in 2009 actually contains. Reading UTF-8 is not
# enough on its own - the bytes have to be scrubbed, or `match?` raises
# ArgumentError instead of answering.
class Ancien < ApplicationRecord
  default_scope { where(actif: true) }
end
