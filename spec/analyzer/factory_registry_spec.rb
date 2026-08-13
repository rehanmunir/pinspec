# frozen_string_literal: true

RSpec.describe Pinspec::Analyzer::FactoryRegistry do
  def index(app)
    described_class.read(File.expand_path("../fixtures/apps/#{app}", __dir__))
  end

  describe "a modern factory_bot suite" do
    subject(:idx) { index("basic_app") }

    it "finds every factory, including nested ones, in declaration order" do
      expect(idx.factories.map(&:name)).to eq(
        %i[
          comparison customer premium_customer product premium_product report_stub
          invoice paid_invoice discounted_invoice line_item
        ]
      )
    end

    it "reports the modern DSL" do
      expect(idx.legacy_dsl).to be(false)
      expect(idx.dsl_module).to eq("FactoryBot")
      expect(idx.skipped).to be_empty
    end

    it "infers the model from the factory name" do
      expect(idx.factory(:invoice).model).to eq("Invoice")
      expect(idx.factory(:line_item).model).to eq("LineItem")
    end

    it "honours an explicit class:" do
      expect(idx.factory(:customer).model).to eq("Billing::Customer")
      expect(idx.factory(:report_stub).model).to eq("Report")
    end

    it "gives a nested factory its parent's class, not its own name" do
      expect(idx.factory(:paid_invoice).model).to eq("Invoice")
      expect(idx.factory(:premium_customer).model).to eq("Billing::Customer")
    end

    it "inherits a class through parent: even when the factory is not nested" do
      expect(idx.factory(:discounted_invoice).parent).to eq(:invoice)
      expect(idx.factory(:discounted_invoice).model).to eq("Invoice")
    end

    it "links nested and parent: factories to their parent" do
      expect(idx.factory(:paid_invoice).parent).to eq(:invoice)
      expect(idx.factory(:premium_product).parent).to eq(:product)
      expect(idx.factory(:invoice).parent).to be_nil
    end

    it "resolves a factory by alias" do
      expect(idx.factory(:buyer).name).to eq(:customer)
      expect(idx.factory(:payer).name).to eq(:customer)
      expect(idx.factory(:customer).aliases).to eq(%i[buyer payer])
    end

    it "finds every factory for a model" do
      expect(idx.for_model("Billing::Customer").map(&:name)).to eq(%i[customer premium_customer])
    end

    describe "attribute kinds" do
      it "records a block attribute as its source text, unevaluated" do
        total = idx.factory(:invoice).attribute(:total)

        expect(total.kind).to eq(:block)
        expect(total.source).to eq("100.0")
      end

      it "treats a bare word as an implicit association" do
        customer = idx.factory(:invoice).attribute(:customer)

        expect(customer.kind).to eq(:association)
        expect(customer).to be_association
        expect(customer.source).to be_nil
      end

      it "records an explicit association with its factory override" do
        product = idx.factory(:line_item).attribute(:product)

        expect(product.kind).to eq(:association)
        expect(product.factory).to eq(:premium_product)
        expect(product.source).to be_nil
      end

      it "records a sequence, keeping the block that shapes it" do
        number = idx.factory(:invoice).attribute(:number)

        expect(number.kind).to eq(:sequence)
        expect(number.source).to include("INV-")
      end

      it "marks transient attributes, which are not columns" do
        line_count = idx.factory(:invoice).attribute(:line_count)

        expect(line_count.kind).to eq(:transient)
        expect(line_count).to be_transient
      end

      it "lists only the real associations" do
        expect(idx.factory(:line_item).associations.map(&:name)).to eq(%i[invoice product])
      end
    end

    describe "traits, in declared order" do
      it "keeps traits in the order written" do
        expect(idx.factory(:invoice).traits.map(&:name)).to eq(%i[paid overdue])
      end

      it "records each trait's own attributes" do
        expect(idx.factory(:invoice).trait(:paid).attributes.map(&:name)).to eq(%i[paid status])
      end

      it "exposes traits inherited from a parent factory" do
        expect(idx.traits_for(:paid_invoice).map(&:name)).to eq(%i[paid overdue])
      end
    end

    describe "callbacks, which fire during setup" do
      it "records after(:create) with its line" do
        callbacks = idx.factory(:invoice).callbacks

        expect(callbacks.map(&:to_s)).to eq(["after(:create)"])
        expect(callbacks.first.line).to be > 0
        expect(idx.factory(:invoice)).to be_fires_callbacks
      end

      it "does not mistake a callback for an attribute" do
        expect(idx.factory(:invoice).attribute(:after)).to be_nil
      end

      it "does not mistake an attribute named before or after for a callback" do
        comparison = idx.factory(:comparison)

        expect(comparison.callbacks).to be_empty
        expect(comparison.attributes.map(&:name)).to eq(%i[before after caption])
        expect(comparison.attribute(:after).kind).to eq(:block)
        expect(comparison.attribute(:after).source).to eq('"new.jpg"')
      end

      it "leaves callback-free factories alone" do
        expect(idx.factory(:product).fires_callbacks?).to be(false)
      end
    end

    describe "hazards" do
      it "records skip_create and initialize_with, and says the factory never persists" do
        report = idx.factory(:report_stub)

        expect(report.hazards.map(&:first)).to eq(%i[skip_create initialize_with])
        expect(report.persists?).to be(false)
      end

      it "does not treat a hazard call as an attribute" do
        expect(idx.factory(:report_stub).attribute(:skip_create)).to be_nil
        expect(idx.factory(:report_stub).attributes.map(&:name)).to eq([:title])
      end

      it "leaves an ordinary factory persisting" do
        expect(idx.factory(:invoice).persists?).to be(true)
      end
    end

    describe "inheritance resolution" do
      it "walks the parent chain root-first" do
        expect(idx.ancestry(:premium_product).map(&:name)).to eq(%i[product premium_product])
        expect(idx.ancestry(:invoice).map(&:name)).to eq([:invoice])
      end

      it "merges inherited attributes with the child's own" do
        expect(idx.attributes_for(:premium_customer).map(&:name)).to eq(%i[name email region])
        expect(idx.attributes_for(:paid_invoice).map(&:name))
          .to eq(%i[customer number total status line_count paid])
      end

      it "lets a child override an inherited attribute" do
        name = idx.attributes_for(:premium_product).find { |a| a.name == :name }

        expect(name.source).to eq('"Premium Widget"')
      end

      it "applies traits last, so a trait overrides the base attribute" do
        status = idx.attributes_for(:invoice, traits: [:paid]).find { |a| a.name == :status }

        expect(status.source).to eq('"paid"')
      end

      it "finds a trait declared on an ancestor" do
        expect(idx.attributes_for(:paid_invoice, traits: [:overdue]).map(&:name)).to include(:due_on)
      end

      it "terminates on mutually parented factories instead of looping forever" do
        cyclic = index("cyclic_app")

        expect(cyclic.ancestry(:chicken).map(&:name)).to contain_exactly(:chicken, :egg)
        expect(cyclic.attributes_for(:chicken).map(&:name)).to eq([:name])
      end

      it "returns nothing for an unknown factory rather than raising" do
        expect(idx.ancestry(:nope)).to be_empty
        expect(idx.attributes_for(:nope)).to be_empty
      end
    end
  end

  describe "a legacy factory_girl suite" do
    subject(:idx) { index("legacy_app") }

    it "reports the legacy DSL, which decides what the emitted spec calls" do
      expect(idx.legacy_dsl).to be(true)
      expect(idx.dsl_module).to eq("FactoryGirl")
    end

    it "reads factories from test/factories as well as spec/factories" do
      expect(idx.factories.map(&:name)).to eq(%i[customer invoice])
    end

    it "records pre-block static attributes with their literal source" do
      name = idx.factory(:customer).attribute(:name)

      expect(name.kind).to eq(:static)
      expect(name.source).to eq('"Acme"')

      expect(idx.factory(:invoice).attribute(:total).kind).to eq(:static)
      expect(idx.factory(:invoice).attribute(:total).source).to eq("100.0")
    end

    it "still sees implicit associations and traits" do
      expect(idx.factory(:invoice).attribute(:customer)).to be_association
      expect(idx.factory(:invoice).trait(:paid).attributes.map(&:name)).to eq([:paid])
    end
  end

  describe "files it cannot use" do
    subject(:idx) { index("broken_app") }

    it "keeps going past an unparsable factory file, and says which" do
      unparsable = idx.skipped.find { |s| s[:kind] == :unparsable }

      expect(unparsable[:file]).to end_with("broken.rb")
      expect(unparsable[:detail]).to match(/line \d+/)
    end

    it "reports a file under spec/factories that declares nothing" do
      expect(idx.skipped.map { |s| s[:kind] }).to include(:no_factories)
    end

    it "never silently returns a shorter list" do
      expect(idx.factories).to be_empty
      expect(idx.skipped.size).to eq(2)
    end
  end

  describe "an app with no factories at all" do
    it "returns an empty index rather than raising" do
      idx = index("full_app")

      expect(idx.factories).to be_empty
      expect(idx.skipped).to be_empty
      expect(idx.dsl_module).to eq("FactoryBot")
    end
  end
end
