ActiveRecord::Schema.define(version: 2026_08_12_000000) do
  enable_extension "plpgsql"

  create_table "shops", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "reference", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["reference"], name: "index_orders_on_reference", unique: true
  end

  add_foreign_key "orders", "shops"
end
