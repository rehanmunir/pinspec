# frozen_string_literal: true

ActiveRecord::Schema[7.1].define(version: 2026_01_01_000000) do
  create_table "shop_users", force: :cascade do |t|
    t.string "email", null: false
    t.timestamps
  end

  create_table "shop_orders", force: :cascade do |t|
    t.references "shop_user", null: false, foreign_key: true
    t.decimal "total", precision: 10, scale: 2, default: "0.0", null: false
    t.string "status", default: "cart"
    t.timestamps
  end

  create_table "proxy_orders", force: :cascade do |t|
    t.references "shop_order", null: false, foreign_key: true
    t.timestamps
  end

  create_table "warehouses", force: :cascade do |t|
    t.string "name", null: false
    t.timestamps
  end
end
