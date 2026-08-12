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
    # A real association sitting beside an unrelated label column. The _type
    # sibling rule cannot tell this apart from a polymorphic pair, and drops the
    # foreign key. Documented in the spec below: failing toward instability beats
    # failing toward a wrong rewrite.
    t.bigint "customer_id"
    t.string "customer_type", default: "retail"
  end

  # There is no company_id column on legacy_codes, so no implicit column can be
  # derived. A real dump never looks like this; the point is that a schema which
  # does not fit the rules loses a foreign key loudly rather than silently.
  add_foreign_key "legacy_codes", "companies"
end
