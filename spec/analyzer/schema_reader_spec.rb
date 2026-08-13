# frozen_string_literal: true

# M-02 acceptance, spec v0.3 §7. The fk_map examples matter most: it is the map
# the probe uses to tell a foreign key from a quantity, and without it the
# identity rewriting in T1-2 cannot work at all.
RSpec.describe Pinspec::Analyzer::SchemaReader do
  def read(name)
    described_class.parse(File.expand_path("../fixtures/schemas/#{name}.rb", __dir__))
  end

  def app(name)
    File.expand_path("../fixtures/apps/#{name}", __dir__)
  end

  describe "a current Rails dump" do
    subject(:graph) { read("basic_schema") }

    it "finds every table" do
      expect(graph.table_names).to eq(%w[customers invoices line_items products reports])
    end

    it "adds the implicit primary key Rails does not write out" do
      id = graph.table("invoices").column("id")

      expect(id.type).to eq(:bigint)
      expect(id.nullable?).to be(false)
      expect(graph.table("invoices").primary_key).to eq("id")
    end

    it "records column modifiers" do
      total = graph.table("invoices").column("total")

      expect(total.type).to eq(:decimal)
      expect(total.precision).to eq(10)
      expect(total.scale).to eq(2)
      expect(total.default).to eq("0.0")
      expect(total.nullable?).to be(false)

      expect(graph.table("customers").column("region").limit).to eq(2)
      expect(graph.table("invoices").column("paid").default).to be(false)
      expect(graph.table("invoices").column("due_on").nullable?).to be(true)
    end

    it "distinguishes a column that needs a value from one with a default" do
      required = graph.table("invoices").required_columns.map(&:name)

      expect(required).to include("customer_id", "number")
      expect(required).not_to include("id", "total", "status", "paid", "due_on")
    end

    it "expands t.references and t.belongs_to into columns, honouring type:" do
      line_items = graph.table("line_items")

      expect(line_items.column("invoice_id").type).to eq(:bigint)
      expect(line_items.column("invoice_id").nullable?).to be(false)
      expect(line_items.column("product_id").type).to eq(:uuid)
    end

    it "expands t.timestamps" do
      expect(graph.table("line_items").column("created_at").type).to eq(:datetime)
      expect(graph.table("line_items").column("updated_at").nullable?).to be(false)
    end

    it "records single, composite, and unique indexes" do
      expect(graph.table("customers").unique_indexes.map(&:columns)).to eq([%w[email]])

      invoices = graph.table("invoices")
      expect(invoices.indexes.map(&:columns)).to include(%w[customer_id], %w[customer_id number])
      expect(invoices.unique_indexes.map(&:columns)).to eq([%w[customer_id number]])
    end

    it "reads a non-default primary key type" do
      expect(graph.table("products").id_type).to eq(:uuid)
      expect(graph.table("products").column("id").type).to eq(:uuid)
    end

    it "builds the fk_map the probe needs" do
      expect(graph.fk_map).to eq(
        "invoices.customer_id"  => "customers",
        "line_items.invoice_id" => "invoices",
        "line_items.product_id" => "products"
      )
    end

    it "derives the implicit column of add_foreign_key against columns that exist" do
      # "invoices".singularize could plausibly be "invoic"; only the schema knows.
      fk = graph.fk_for("line_items", "invoice_id")

      expect(fk).not_to be_nil
      expect(fk.to_table).to eq("invoices")
      expect(fk.on_delete).to eq(:cascade)
      expect(graph.fk_map.keys).not_to include("line_items.invoic_id")
    end

    it "prefers a database constraint over an inferred association" do
      expect(graph.fk_for("invoices", "customer_id").source).to eq(:foreign_key)
      expect(graph.fk_for("line_items", "product_id").source).to eq(:references)
    end

    it "treats enable_extension as understood, not as a hazard" do
      expect(graph.skipped_statements).to be_empty
    end
  end

  describe "a schema full of hazards" do
    subject(:graph) { read("full_schema") }

    it "expands a polymorphic reference into both columns" do
      orders = graph.table("orders")

      expect(orders.column("owner_id").type).to eq(:bigint)
      expect(orders.column("owner_type").type).to eq(:string)
    end

    it "gives a polymorphic id no fk_map entry, because the target is a runtime value" do
      expect(graph.fk_map).not_to have_key("orders.owner_id")
      expect(graph.fk_for("orders", "owner_id")).to be_nil
    end

    # These two are the cases that matter: the stem resolves to a real table, so
    # every tier *would* happily claim the column. Rewriting a polymorphic id to
    # one table is how the probe ends up rewriting the wrong integer.
    it "excludes a polymorphic id whose stem does match a table" do
      expect(graph.table("audit_entries").column("company_id")).not_to be_nil
      expect(graph.table("companies")).not_to be_nil
      expect(graph.fk_map).not_to have_key("audit_entries.company_id")
    end

    it "excludes a hand-written owner_id/owner_type pair, as pre-references schemas have" do
      legacy = graph.table("legacy_codes")

      expect(legacy.column("company_id")).not_to be_nil
      expect(legacy.column("company_type")).not_to be_nil
      expect(graph.fk_map).not_to have_key("legacy_codes.company_id")
    end

    it "infers an undeclared association from the column name, and flags it" do
      fk = graph.fk_for("orders", "person_id")

      expect(fk.to_table).to eq("people") # irregular plural, resolved against real tables
      expect(fk.source).to eq(:heuristic)
      expect(fk).to be_heuristic
    end

    it "leaves a *_id column with no matching table alone" do
      expect(graph.table("orders").column("external_id")).not_to be_nil
      expect(graph.fk_map).not_to have_key("orders.external_id")
    end

    it "honours an explicit column: on add_foreign_key" do
      fk = graph.fk_for("orders", "warehouse_id")

      expect(fk.source).to eq(:foreign_key)
      expect(fk.on_delete).to eq(:nullify)
    end

    it "derives an implicit column that a first-guess singularizer would get wrong" do
      # "addresses" strips to "addresse" before "address"; only the column list
      # settles it. Nothing else in this schema forces that check.
      fk = graph.fk_for("orders", "address_id")

      expect(fk.to_table).to eq("addresses")
      expect(fk.source).to eq(:foreign_key)
      expect(graph.fk_map.keys).not_to include("orders.addresse_id")
    end

    it "honours an explicit primary_key: on add_foreign_key" do
      fk = graph.fk_for("audit_entries", "actor_id")

      expect(fk.to_table).to eq("people")
      expect(fk.primary_key).to eq("id")
    end

    it "records array columns and partial indexes" do
      expect(graph.table("orders").column("tags").array).to be(true)

      partial = graph.table("orders").indexes.find(&:partial?)
      expect(partial.columns).to eq(%w[status])
      expect(partial.where).to include("cancelled")
    end

    it "attaches a top-level add_index to its table" do
      expect(graph.table("orders").indexes.map(&:columns)).to include(%w[warehouse_id])
    end

    it "handles id: false with a replacement primary key" do
      legacy = graph.table("legacy_codes")

      expect(legacy.primary_key).to eq("code")
      expect(legacy.id_type).to be_nil
      expect(legacy.column("id")).to be_nil
    end

    it "normalizes a SQL type given to t.column" do
      expect(graph.table("audit_entries").column("recorded_at").type).to eq(:timestamp)
    end

    # The acceptance line: a create_view and a PostGIS column both surface.
    it "records unknown DSL statements without failing" do
      kinds = graph.skipped_statements.map(&:kind)

      expect(kinds).to include(:create_view, :create_enum, :create_function, :add_check_constraint)
    end

    it "records an unknown column type as a hazard, keeping the column" do
      unknown = graph.skipped_statements.select { |s| s.kind == :unknown_column_type }

      expect(unknown.map(&:column)).to contain_exactly("delivery_point", "service_area")
      expect(graph.table("orders").column("delivery_point").type).to eq(:st_point)
      expect(graph.table("orders").column("delivery_point")).to be_unknown_type
    end

    it "keeps a NOT NULL unknown column in required_columns, so M-05 must refuse it" do
      expect(graph.table("orders").required_columns.map(&:name)).to include("service_area")
      expect(graph.table("orders").required_columns.map(&:name)).not_to include("delivery_point")
    end

    it "reports the line of every hazard, sorted" do
      lines = graph.skipped_statements.map(&:line)

      expect(lines).to eq(lines.sort)
      expect(lines).to all(be > 0)
    end

    it "sees which tables a view actually reads, not just the view's own name" do
      view = graph.skipped_statements.find { |s| s.kind == :create_view }

      expect(view.table).to eq("active_orders")
      expect(view.references).to include("orders")
    end

    describe "relevance, which only a plan can decide" do
      it "is unset until a plan exists" do
        expect(graph.skipped_statements.map(&:relevant)).to all(be_nil)
      end

      it "marks a view on a planned table relevant, and an unrelated function not" do
        annotated = graph.annotate_relevance(%w[orders])
        by_kind   = annotated.skipped_statements.group_by(&:kind)

        expect(by_kind[:create_view].first).to be_relevant
        expect(by_kind[:unknown_column_type]).to all(be_relevant)
        expect(by_kind[:create_function].first).not_to be_relevant
        expect(by_kind[:create_enum].first).not_to be_relevant
      end
    end
  end

  describe "a schema that does not fit the rules" do
    subject(:graph) { read("malformed_schema") }

    it "drops an unattachable foreign key loudly rather than inventing a column" do
      expect(graph.skipped_statements.map(&:kind)).to include(:unattachable_foreign_key)
      expect(graph.skipped_statements.find { |s| s.kind == :unattachable_foreign_key }.table)
        .to eq("legacy_codes")
    end

    # A documented trade, not an oversight. The _type sibling rule cannot tell a
    # polymorphic pair from a real foreign key beside a label column, and drops
    # both. Dropping means the id stays a raw integer, which M-08 reports as
    # :identity_churn - visible instability. Claiming it would mean rewriting an
    # id into the wrong table and pinning a lie that looks green.
    it "also drops a real foreign key that sits beside an unrelated _type column" do
      expect(graph.table("invoices").column("customer_id")).not_to be_nil
      expect(graph.table("customers")).not_to be_nil
      expect(graph.fk_map).not_to have_key("invoices.customer_id")
    end
  end

  describe "an old Rails dump" do
    subject(:graph) { read("legacy_schema") }

    it "parses ActiveRecord::Schema.define without a version bracket" do
      expect(graph.table_names).to eq(%w[customers invoices])
    end

    it "infers the association a pre-references-era schema never declared" do
      fk = graph.fk_for("invoices", "customer_id")

      expect(fk.to_table).to eq("customers")
      expect(fk.source).to eq(:heuristic)
    end

    it "tolerates old index options" do
      expect(graph.table("invoices").indexes.map(&:columns)).to eq([%w[customer_id]])
    end
  end

  describe "the wire format" do
    it "is plain strings, so it survives the JSON boundary to the probe" do
      require "json"
      fk_map = read("full_schema").fk_map

      expect(fk_map.keys).to all(be_a(String))
      expect(fk_map.values).to all(be_a(String))
      expect(JSON.parse(JSON.generate(fk_map))).to eq(fk_map)
    end
  end

  describe "refusals" do
    it "refuses a SQL-format schema with the workaround, at exit 6" do
      expect { described_class.parse(File.expand_path("../fixtures/schemas/structure.sql", __dir__)) }
        .to raise_error(Pinspec::SchemaFormatUnsupported) { |error|
          expect(error.exit_code).to eq(6)
          expect(error.message).to include("db:schema:dump")
        }
    end

    it "refuses an app that only has structure.sql" do
      expect { described_class.read(app("sql_app")) }
        .to raise_error(Pinspec::SchemaFormatUnsupported, /structure\.sql/)
    end

    it "reads an app by its root" do
      expect(described_class.read(app("basic_app")).table_names).to include("invoices")
    end

    it "says so when there is no schema at all" do
      expect { described_class.read(File.expand_path("../fixtures", __dir__)) }
        .to raise_error(Pinspec::TargetNotFound, /Rails application root/)
    end

    it "refuses a Ruby file that is not a schema dump" do
      path = File.expand_path("../fixtures/targets/invoice_calculator.rb", __dir__)

      expect { described_class.parse(path) }
        .to raise_error(Pinspec::UnparsableSource, /no ActiveRecord::Schema\.define/)
    end
  end
end

RSpec.describe Pinspec::Analyzer::Inflector do
  describe ".table_candidates" do
    it "puts the irregular plural first" do
      expect(described_class.table_candidates("person").first).to eq("people")
    end

    it "handles consonant-y and sibilant endings" do
      expect(described_class.table_candidates("company")).to include("companies")
      expect(described_class.table_candidates("status")).to include("statuses")
      expect(described_class.table_candidates("box")).to include("boxes")
    end

    it "offers the stem itself, for an already-plural or uncountable name" do
      expect(described_class.table_candidates("metadata")).to include("metadata")
      expect(described_class.table_candidates("orders")).to include("orders")
    end
  end

  describe ".singular_candidates" do
    it "prefers stripping a plain -s over stripping -es" do
      candidates = described_class.singular_candidates("invoices")

      expect(candidates.index("invoice")).to be < candidates.index("invoic")
    end

    it "still offers the -es form, for names that need it" do
      expect(described_class.singular_candidates("statuses")).to include("status")
    end

    it "reverses irregular plurals" do
      expect(described_class.singular_candidates("people").first).to eq("person")
    end
  end
end
