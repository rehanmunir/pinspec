ActiveRecord::Schema[7.1].define(version: 2026_01_01_000000) do
  # Mutually required: neither row can be created first.
  create_table "chickens", force: :cascade do |t|
    t.bigint "egg_id", null: false
    t.string "name", null: false
  end

  create_table "eggs", force: :cascade do |t|
    t.bigint "chicken_id", null: false
  end

  # A NOT NULL foreign key to itself: the row would have to exist before it does.
  create_table "nodes", force: :cascade do |t|
    t.bigint "node_id", null: false
    t.string "label", null: false
  end

  add_foreign_key "chickens", "eggs"
  add_foreign_key "eggs", "chickens"
  add_foreign_key "nodes", "nodes", column: "node_id"
end
