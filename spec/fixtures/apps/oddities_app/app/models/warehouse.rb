class Warehouse < ApplicationRecord
  include Discard::Model

  connects_to database: { writing: :warehouse, reading: :warehouse }
end
