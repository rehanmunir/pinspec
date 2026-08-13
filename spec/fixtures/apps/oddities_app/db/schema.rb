
ActiveRecord::Schema[7.1].define(version: 2026_02_11_094500) do
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
    t.boolean "paid", default: false, null: false
    t.date "due_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_invoices_on_customer_id"
    t.index ["customer_id", "number"], name: "index_invoices_on_customer_and_number", unique: true
  end

  create_table "line_items", force: :cascade do |t|
    t.references "invoice", null: false, foreign_key: true
    t.belongs_to "product", type: :uuid, null: false
    t.integer "quantity", default: 1, null: false
    t.decimal "unit_price", precision: 10, scale: 2, null: false
    t.timestamps
  end

  create_table "products", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "sku", null: false
    t.string "name", null: false
    t.index ["sku"], name: "index_products_on_sku", unique: true
  end

  add_foreign_key "invoices", "customers"
  add_foreign_key "line_items", "invoices", on_delete: :cascade
end
