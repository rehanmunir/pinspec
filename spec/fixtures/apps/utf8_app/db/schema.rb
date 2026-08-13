# frozen_string_literal: true

ActiveRecord::Schema[7.1].define(version: 2026_01_01_000000) do
  create_table "producteurs", force: :cascade do |t|
    t.string "nom", null: false
    # A UTF-8 default value, which a schema really does carry.
    t.string "devise", default: "€", null: false
    t.string "ville", default: "Montréal"
    t.timestamps
  end

  create_table "paniers", force: :cascade do |t|
    t.references "producteur", null: false, foreign_key: true
    t.decimal "prix", precision: 8, scale: 2, default: "0.0", null: false
    t.timestamps
  end
end
