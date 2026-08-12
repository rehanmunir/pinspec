ActiveRecord::Schema.define(version: 20180419103012) do

  create_table "customers", force: :cascade do |t|
    t.string   "name",       limit: 255
    t.string   "email"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "invoices", force: :cascade do |t|
    t.integer  "customer_id"
    t.decimal  "total",       precision: 8, scale: 2
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  add_index "invoices", ["customer_id"], name: "index_invoices_on_customer_id", using: :btree
end
