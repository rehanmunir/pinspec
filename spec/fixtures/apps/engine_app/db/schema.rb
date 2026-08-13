# frozen_string_literal: true

ActiveRecord::Schema[7.1].define(version: 2026_01_01_000000) do
  create_table "shop_users", force: :cascade do |t|
    t.string "email", null: false
    t.timestamps
  end

  # Deliberately TWO tables whose names end in "_orders", so a suffix guess is
  # genuinely ambiguous and only the factory's declared class can settle it. Open
  # Food Network has exactly this shape: spree_orders and proxy_orders.
  create_table "shop_orders", force: :cascade do |t|
    t.references "shop_user", null: false, foreign_key: true
    t.decimal "total", precision: 10, scale: 2, default: "0.0", null: false
    # A status column, because the ubiquitous `case status` service object is the
    # highest-coverage win sampling has: rows are stratified by it so each branch gets
    # a real row rather than three copies of the same state.
    t.string "status", default: "cart"
    t.timestamps
  end

  create_table "proxy_orders", force: :cascade do |t|
    t.references "shop_order", null: false, foreign_key: true
    t.timestamps
  end

  # No table for "Distributor", which is what makes the refusal reachable.
  create_table "warehouses", force: :cascade do |t|
    t.string "name", null: false
    t.timestamps
  end
end
