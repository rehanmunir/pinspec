# frozen_string_literal: true

# M-06 acceptance, spec v0.3 §7 - the input half. The allocation examples matter
# most: a `#call` target keeps its dependencies in the constructor, so a budget
# spent entirely on constructor parameters leaves the method's own arguments
# untested.
RSpec.describe Pinspec::Inputs::Corpus do
  def parts_for(app, service, method = "call")
    root    = File.expand_path("../fixtures/apps/#{app}", __dir__)
    target  = Pinspec::Analyzer::TargetParser.parse(File.join(root, "app/services", service), method)
    profile = Pinspec::Analyzer::AppProfileReader.read(root)

    [target, Pinspec::Setup::ContextBuilder.build(target: target, profile: profile), profile]
  end

  def corpus(app, service, method = "call", max_cases: 12)
    target, plan, profile = parts_for(app, service, method)

    described_class.build(target: target, plan: plan, schema: profile.schema, max_cases: max_cases)
  end

  def kwargs_of(input_case, name)
    Pinspec::Tags.decode(input_case.ctor_kwargs[name] || input_case.kwargs[name])
  end

  describe "case one, which every later case is measured against" do
    subject(:first) { corpus("basic_app", "invoice_calculator.rb").cases.first }

    it "is the all-defaults case" do
      expect(first.id).to eq("c001")
      expect(first.origin).to eq(:defaults)
      expect(kwargs_of(first, "tax_rate")).to eq(0.08)
    end

    it "passes the plan's ref for a model-typed parameter, never an id" do
      # Ids come from sequences, and sequences do not roll back.
      expect(first.ctor_args.first).to eq("t" => "ref", "v" => "invoice_1")
    end
  end

  describe "one factor at a time" do
    subject(:cases) { corpus("basic_app", "invoice_calculator.rb").cases }

    it "varies a single parameter per case, holding the rest at their base" do
      varied = cases.drop(1)

      expect(varied.map(&:origin).uniq).to eq([:boundary])
      expect(varied.map { |c| kwargs_of(c, "tax_rate") }.compact).to eq([0.0, 1.0, -1.0])
      # The ref never changes: varying a ref would vary the world, not the input.
      expect(varied.map { |c| c.ctor_args.first["v"] }.uniq).to eq(["invoice_1"])
    end

    # An omitted argument runs the method's own default expression, and a default
    # can read the clock or a feature flag.
    it "omits an optional argument entirely in one case" do
      omitted = cases.find { |c| c.ctor_kwargs.empty? }

      expect(omitted).not_to be_nil
      expect(omitted.origin).to eq(:boundary)
      expect(omitted.ctor_args.first["v"]).to eq("invoice_1")
    end

    it "never omits a required argument" do
      expect(cases.map { |c| c.ctor_args.size }.uniq).to eq([1])
    end

    it "never varies a model-typed parameter" do
      expect(cases.map { |c| c.ctor_args.size }.uniq).to eq([1])
    end

    it "numbers cases in a stable, sortable order" do
      expect(cases.map(&:id)).to eq(cases.map(&:id).sort)
      expect(cases.first.id).to eq("c001")
    end
  end

  describe "budget allocation across ctor and method parameters" do
    # The acceptance criterion: three constructor parameters and a method
    # parameter, under a budget too small for both lists.
    subject(:cases) { corpus("full_app", "order_pricer.rb", "call", max_cases: 5).cases }

    it "respects the cap" do
      expect(cases.size).to eq(5)
    end

    it "reaches a method parameter rather than spending everything on the ctor" do
      express = cases.find { |c| kwargs_of(c, "express") == true }

      expect(express).not_to be_nil
      expect(express.id).to eq("c003") # interleaved, so it arrives early
    end

    it "still varies constructor parameters" do
      discounts = cases.map { |c| kwargs_of(c, "discount") }.uniq

      expect(discounts).to include(0.1, 0.0, 1.0)
    end

    it "generates more when given a larger budget" do
      expect(corpus("full_app", "order_pricer.rb", "call", max_cases: 12).size).to be > 5
    end
  end

  describe "parameters pinspec will not generate values for" do
    subject(:cases) { corpus("basic_app", "bulk_importer.rb").cases }

    it "spends the whole budget on parameters that can actually vary" do
      # *extras, **options and *rest cannot be varied, and a variation for one
      # would consume a case slot only for dedup to discard it - leaving a target
      # with splats fewer real cases than its budget allows.
      tight = corpus("basic_app", "bulk_importer.rb", "call", max_cases: 4)

      expect(tight.size).to eq(4)
      expect(tight.cases.map { |c| Pinspec::Tags.decode(c.args[1]) }.compact.uniq.size).to be > 1
    end

    it "never renders a splat as an argument" do
      # number and batch_size, never *rest. One case omits batch_size, so the
      # ceiling is what matters.
      expect(cases.map { |c| c.args.size }.max).to eq(2)
      expect(cases.map { |c| c.ctor_args.size }.max).to eq(1) # customer, never *extras
      expect(cases.map { |c| c.ctor_kwargs }.uniq).to eq([{}]) # never **options
    end

    it "declines an ambiguous column type rather than guessing" do
      # `number` is a string on invoices and an integer on reports.
      expect(Pinspec::Tags.decode(cases.first.args.first)).to be_nil
    end
  end

  describe "typing a parameter" do
    it "prefers the declared default literal" do
      cases = corpus("basic_app", "invoice_calculator.rb").cases

      expect(kwargs_of(cases.first, "tax_rate")).to eq(0.08)
    end

    it "falls back to a schema column of the same name" do
      # `region` hints at a "Region" model that does not exist, but customers.region
      # is a string - and the schema is a fact where the name is a guess.
      cases = corpus("basic_app", "customer_report.rb", "Reports::CustomerReport.call").cases
      regions = cases.map { |c| Pinspec::Tags.decode(c.args.first) }.uniq

      expect(regions).to include("", "pinspec")
    end

    it "passes nil when nothing is known, which exercises the commonest legacy crash" do
      # full_app has no `quantity` column anywhere.
      cases = corpus("full_app", "order_pricer.rb").cases

      expect(Pinspec::Tags.decode(cases.first.args.first)).to be_nil
    end
  end

  describe "encoding" do
    subject(:first) { corpus("full_app", "order_pricer.rb").cases.first }

    it "tags every value, including ones JSON could carry natively" do
      # A bare 5 would be ambiguous between an Integer and a whole decimal, and the
      # probe would have to guess.
      (first.ctor_args + first.args + first.ctor_kwargs.values + first.kwargs.values).each do |value|
        expect(value).to be_a(Hash)
        expect(value).to have_key("t")
      end
    end

    it "separates positional from keyword arguments" do
      expect(first.ctor_args.size).to eq(1)
      expect(first.ctor_kwargs.keys).to eq(%w[discount currency rounding])
      expect(first.kwargs.keys).to eq(["express"])
    end

    it "survives a JSON round trip, since cases.json is the boundary" do
      require "json"
      round_tripped = JSON.parse(JSON.generate(first.ctor_kwargs))

      expect(round_tripped).to eq(first.ctor_kwargs)
    end
  end

  describe "deduplication" do
    it "keeps no two cases with identical arguments" do
      cases = corpus("full_app", "order_pricer.rb", "call", max_cases: 12).cases

      expect(cases.map(&:signature).uniq.size).to eq(cases.size)
    end

    it "produces only the defaults case when there is nothing to vary" do
      # Both parameters are refs.
      cases = corpus("full_app", "company_merger.rb").cases

      expect(cases.size).to eq(1)
      expect(cases.first.origin).to eq(:defaults)
    end
  end
end

RSpec.describe Pinspec::Inputs::Boundary do
  def param(name, kind: :key, default: nil, hint: nil)
    Pinspec::Param.new(name: name, kind: kind, default_source: default, type_hint: hint)
  end

  def decoded(values)
    values.map { |value| Pinspec::Tags.decode(value) }
  end

  it "puts the declared default first, because it is the real behaviour" do
    values = described_class.values_for(param(:rate, default: "0.5", hint: "Float"))

    expect(decoded(values).first).to eq(0.5)
  end

  it "reads a default from source text without evaluating it" do
    expect(decoded(described_class.values_for(param(:flag, default: "true")))).to include(true)
    expect(decoded(described_class.values_for(param(:mode, default: ":fast")))).to include(:fast)
    expect(decoded(described_class.values_for(param(:label, default: '"hi"')))).to include("hi")
    expect(decoded(described_class.values_for(param(:nothing, default: "nil")))).to include(nil)
  end

  it "omits a computed default rather than guessing at its value" do
    values = described_class.values_for(param(:at, default: "Time.now", hint: "Time"))

    expect(decoded(values)).not_to include("Time.now")
  end

  it "offers edges per type" do
    expect(decoded(described_class.values_for(param(:n, hint: "Integer")))).to eq([0, 1, -1])
    expect(decoded(described_class.values_for(param(:b, hint: "Boolean")))).to eq([true, false])
    expect(decoded(described_class.values_for(param(:s, hint: "String")))).to eq(["", "pinspec"])
  end

  it "keeps a decimal a string, so a pinned total cannot drift through a Float" do
    values = described_class.values_for(param(:total, hint: "BigDecimal"))

    expect(values.map { |v| v["t"] }.uniq).to eq(["decimal"])
    expect(decoded(values)).to eq(%w[0.0 1.0 -1.0])
  end

  it "offers only the declared value for a Symbol, since nothing else is meaningful" do
    values = described_class.values_for(param(:rounding, default: ":up", hint: "Symbol"))

    expect(decoded(values)).to eq([:up])
  end
end
