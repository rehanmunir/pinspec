ActiveRecord::Schema[7.1].define(version: 2026_01_01_000000) do
  create_table "companies", force: :cascade do |t|
    t.string "name"
  end

  create_table "legacy_codes", id: false, primary_key: "code", force: :cascade do |t|
    t.string "code", null: false
  end

  create_table "customers", force: :cascade do |t|
    t.string "name"
  end

  create_table "invoices", force: :cascade do |t|
    t.bigint "customer_id"
    t.string "customer_type", default: "retail"
  end

  add_foreign_key "legacy_codes", "companies"
end
