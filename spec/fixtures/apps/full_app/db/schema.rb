ActiveRecord::Schema[7.1].define(version: 2026_03_02_120000) do
  enable_extension "pgcrypto"
  enable_extension "postgis"

  create_enum "order_status", ["pending", "shipped", "cancelled"]

  create_table "warehouses", force: :cascade do |t|
    t.string "code", null: false
  end

  create_table "companies", force: :cascade do |t|
    t.string "name", null: false
    t.index ["name"], name: "index_companies_on_name", unique: true
  end

  create_table "people", force: :cascade do |t|
    t.string "full_name", null: false
  end

  create_table "addresses", force: :cascade do |t|
    t.string "line1", null: false
  end

  create_table "orders", force: :cascade do |t|
    t.references "company", null: false, foreign_key: true
    t.references "owner", polymorphic: true, null: false
    t.bigint "warehouse_id"
    t.bigint "person_id"
    t.bigint "address_id"
    t.integer "external_id"
    t.integer "line_item_count", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.string "tags", array: true, default: []
    t.st_point "delivery_point"
    t.geography "service_area", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "status"], name: "index_orders_on_company_and_status", unique: true
    t.index ["status"], name: "index_orders_on_status", where: "(status <> 'cancelled'::text)"
  end

  create_table "contracts", force: :cascade do |t|
    t.references "company", null: false, foreign_key: true
    t.bigint "warehouse_id"
    t.string "title", null: false
    t.string "code", limit: 4, null: false
    t.datetime "signed_at", null: false
    t.date "starts_on", null: false
  end

  create_table "legacy_codes", id: false, primary_key: "code", force: :cascade do |t|
    t.string "code", null: false
    t.string "label"
    t.bigint "company_id"
    t.string "company_type"
  end

  create_table "audit_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_id"
    t.references "company", polymorphic: true
    t.jsonb "payload", default: {}, null: false
    t.column "recorded_at", "timestamp without time zone"
  end

  add_index "orders", ["warehouse_id"], name: "index_orders_on_warehouse_id"
  add_foreign_key "orders", "warehouses", column: "warehouse_id", on_delete: :nullify
  add_foreign_key "orders", "addresses"
  add_foreign_key "audit_entries", "people", column: "actor_id", primary_key: "id"

  add_check_constraint "orders", "line_item_count >= 0", name: "orders_count_non_negative"

  create_view "active_orders", sql_definition: <<-SQL
      SELECT orders.id, orders.status FROM orders WHERE (orders.status <> 'cancelled'::text);
  SQL

  create_function "bump_updated_at", sql_definition: <<~SQL
      CREATE OR REPLACE FUNCTION bump_updated_at() RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql;
  SQL
end
