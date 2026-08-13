ActiveRecord::Schema[7.0].define(version: 2026_08_12_000000) do
  enable_extension "plpgsql"

  create_table "customers", force: :cascade do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.string "region", limit: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_customers_on_email", unique: true
  end

  create_table "invoices", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.string "number", null: false
    t.decimal "total", precision: 10, scale: 2, default: "0.0", null: false
    t.string "status", default: "draft", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_invoices_on_customer_id"
    t.index ["number"], name: "index_invoices_on_number", unique: true
  end

  create_table "line_items", force: :cascade do |t|
    t.references "invoice", null: false, foreign_key: true
    t.integer "quantity", default: 1, null: false
    t.decimal "unit_price", precision: 10, scale: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "invoices", "customers"
end
