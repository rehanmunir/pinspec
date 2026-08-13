# frozen_string_literal: true

# The half of M-05 that answers "what does Invoice mean" - the question most
# likely to be wrong on a real app, which is why it has its own file.
RSpec.describe Pinspec::Setup::DependencyResolver do
  def resolver_for(app)
    profile = Pinspec::Analyzer::AppProfileReader.read(
      File.expand_path("../fixtures/apps/#{app}", __dir__)
    )

    [described_class.new(profile.schema, profile.factories), profile]
  end

  let(:basic) { resolver_for("basic_app").first }
  let(:full)  { resolver_for("full_app").first }

  describe "#table_for" do
    it "resolves a model name to its table" do
      expect(basic.table_for("Invoice").name).to eq("invoices")
      expect(basic.table_for("LineItem").name).to eq("line_items")
    end

    it "drops a namespace, as Rails does without a table_name_prefix" do
      expect(basic.table_for("Billing::Customer").name).to eq("customers")
    end

    it "handles an irregular plural by checking what exists" do
      expect(full.table_for("Person").name).to eq("people")
    end

    it "returns nil rather than inventing a table" do
      expect(basic.table_for("Nonexistent")).to be_nil
      expect(basic.table_for(nil)).to be_nil
    end
  end

  describe "#table_for_type_hint" do
    # A hint is a guess made from a parameter's name, and real names carry
    # qualifiers: source_company, new_invoice, original_line_item.
    it "drops leading qualifier words until something resolves" do
      expect(full.table_for_type_hint("SourceCompany").name).to eq("companies")
      expect(basic.table_for_type_hint("OriginalLineItem").name).to eq("line_items")
    end

    it "prefers the whole hint, so a real model wins over a suffix" do
      # LineItem must resolve as itself, not by dropping "Line" to reach Item.
      expect(basic.table_for_type_hint("LineItem").name).to eq("line_items")
    end

    it "gives up rather than matching something unrelated" do
      expect(basic.table_for_type_hint("TotallyUnknownThing")).to be_nil
      expect(basic.table_for_type_hint(nil)).to be_nil
    end
  end

  describe "#model_for" do
    it "prefers a factory's declared class over the naming convention" do
      # basic_app's :customer factory declares class: "Billing::Customer", which is
      # a fact; "Customer" would only be a convention.
      expect(basic.model_for("customers")).to eq("Billing::Customer")
    end

    it "falls back to singularize + camelize" do
      expect(full.model_for("companies")).to eq("Company")
      expect(full.model_for("people")).to eq("Person")
      expect(full.model_for("contracts")).to eq("Contract")
    end
  end

  describe "#factory_for" do
    it "finds the factory for a table" do
      expect(basic.factory_for("invoices").name).to eq(:invoice)
    end

    it "declines a factory that never persists, so no world is founded on it" do
      # :report_stub uses skip_create. Its model resolves to the reports table, so
      # the only thing standing between it and a plan is the persistence check.
      expect(basic.table_for("Report").name).to eq("reports")
      expect(basic.factory_for("reports")).to be_nil
      expect(basic.declined_factory_for("reports").name).to eq(:report_stub)
    end

    it "returns nil for a table nothing declares" do
      expect(full.factory_for("companies")).to be_nil
    end
  end

  describe "#required_associations" do
    it "lists only foreign keys a row cannot exist without" do
      expect(full.required_associations(full_table("contracts")))
        .to eq([["company_id", "companies"]])
    end

    it "omits a nullable foreign key, leaving the smallest world that exists" do
      # contracts.warehouse_id is nullable.
      expect(full.required_associations(full_table("contracts")).map(&:first))
        .not_to include("warehouse_id")
    end

    it "is empty for a table with no required parents" do
      expect(full.required_associations(full_table("companies"))).to be_empty
      expect(full.required_associations(nil)).to be_empty
    end
  end

  describe "#creation_order" do
    it "puts a parent before the row that needs it" do
      order = full.creation_order(["contracts"])

      expect(order.index("companies")).to be < order.index("contracts")
    end

    it "stops descending at a pruned table, whose parents someone else builds" do
      order = full.creation_order(["contracts"], prune: ->(name) { name == "contracts" })

      expect(order).to eq(["contracts"])
    end

    it "raises on two tables that require each other" do
      cycle, = resolver_for("cycle_app")

      expect { cycle.creation_order(["chickens"]) }
        .to raise_error(Pinspec::UnresolvableSetup) { |error|
          expect(error.reason).to eq(:association_cycle)
        }
    end
  end

  describe "#placeholder_for" do
    let(:frozen) { Pinspec::PINSPEC_EPOCH }

    def column(type, **options)
      Pinspec::Column.new(
        name: "c", type: type, null: false, default: nil, limit: nil,
        precision: nil, scale: nil, array: false, unknown_type: false, line: 1
      ).with(**options)
    end

    it "fills a temporal column from the plan's frozen clock, never from Time.now" do
      expect(full.placeholder_for(column(:datetime), frozen_time: frozen)).to eq(frozen)
      expect(full.placeholder_for(column(:date), frozen_time: frozen)).to eq("2026-01-01")
      expect(full.placeholder_for(column(:time), frozen_time: frozen)).to eq("12:00:00")
    end

    it "gives a deterministic value per type" do
      expect(full.placeholder_for(column(:string), frozen_time: frozen)).to eq("pinspec")
      expect(full.placeholder_for(column(:integer), frozen_time: frozen)).to eq(1)
      expect(full.placeholder_for(column(:decimal), frozen_time: frozen)).to eq("1.0")
      expect(full.placeholder_for(column(:boolean), frozen_time: frozen)).to be(false)
      expect(full.placeholder_for(column(:jsonb), frozen_time: frozen)).to eq({})
    end

    it "respects a column's length limit" do
      expect(full.placeholder_for(column(:string, limit: 4), frozen_time: frozen)).to eq("pins")
    end

    it "suffixes a string for uniqueness and offsets an integer" do
      expect(full.placeholder_for(column(:string), frozen_time: frozen, uniquifier: "p1-2"))
        .to eq("pinspec-p1-2")
      expect(full.placeholder_for(column(:integer), frozen_time: frozen, uniquifier: "p1-2"))
        .to eq(4) # 1 + (1 + 2)
    end

    it "has no value for a type it does not model" do
      expect(full.placeholder_for(column(:st_point), frozen_time: frozen)).to be_nil
    end
  end

  def full_table(name)
    Pinspec::Analyzer::AppProfileReader
      .read(File.expand_path("../fixtures/apps/full_app", __dir__))
      .schema.table(name)
  end
end
