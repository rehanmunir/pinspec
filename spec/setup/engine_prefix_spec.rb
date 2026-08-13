# frozen_string_literal: true

RSpec.describe "an application built on an engine" do
  def app
    File.expand_path("../fixtures/apps/engine_app", __dir__)
  end

  let(:profile) { Pinspec::Analyzer::AppProfileReader.read(app) }
  let(:resolver) { Pinspec::Setup::DependencyResolver.new(profile.schema, profile.factories) }

  def target(file, method = "call")
    Pinspec::Analyzer::TargetParser.parse(File.join(app, "app/services", file), method)
  end

  def plan_for(file)
    Pinspec::Setup::ContextBuilder.build(target: target(file), profile: profile)
  end

  describe "resolving a model whose table is behind a prefix" do
    it "crosses the prefix when the name is fully qualified" do
      expect(resolver.table_for("Shop::Order")&.name).to eq("shop_orders")
    end

    it "crosses the prefix from a bare parameter hint, via the factory's declared class" do
      expect(resolver.table_for_type_hint("Order")&.name).to eq("shop_orders")
    end

    it "declines to guess from the table names alone, because they are ambiguous" do
      expect(resolver.send(:table_from_unique_prefix, "Order")).to be_nil
    end

    it "uses the unique-suffix fallback only when there is one answer" do
      expect(resolver.send(:table_from_unique_prefix, "User")&.name).to eq("shop_users")
    end

    it "still resolves a plain table with no prefix at all" do
      expect(resolver.table_for_type_hint("Warehouse")&.name).to eq("warehouses")
    end

    it "returns nil for a name the application does not have" do
      expect(resolver.table_for_type_hint("Distributor")).to be_nil
    end
  end

  describe "the plan it builds" do
    subject(:plan) { plan_for("order_summary.rb") }

    it "binds the parameter to a record instead of nil" do
      expect(plan.bindings[:order]).to eq("shop_order_1")
      expect(plan.record_steps.map { |step| step.payload[:name] }).to include("shop_order_1")
    end

    it "uses the factory the app declared for that model" do
      step = plan.record_steps.find { |s| s.payload[:name] == "shop_order_1" }

      expect(step.payload[:factory]).to eq(:order)
      expect(step.payload[:model]).to eq("Shop::Order")
    end

    it "builds no user for a target that cannot observe one" do
      expect(plan.steps_of(:stub_current)).to be_empty
      expect(plan.notes.map { |note| note[:kind] }).to include(:current_user_not_built)
    end
  end

  describe "a parameter it cannot build" do
    it "refuses, rather than passing nil and pinning the resulting error" do
      expect { plan_for("route_planner.rb") }
        .to raise_error(Pinspec::UnresolvableSetup) { |error|
          expect(error.reason).to eq(:unresolvable_parameter)
          expect(error.message).to include("`distributor`")
          expect(error.message).to include("looks like a Distributor")
          expect(error.message).to include("will not pass nil")
          expect(error.message).to include("factory named :distributor")
        }
    end

    it "exits 5, the code for a world that cannot be built" do
      expect(Pinspec::UnresolvableSetup.exit_code).to eq(5)
    end

    it "does not fire for a hint that is not a model name" do
      builder = Pinspec::Setup::ContextBuilder.new(target: target("order_summary.rb"), profile: profile)

      %w[String Hash Integer Params Status Boolean].each do |hint|
        param = Pinspec::Param.new(name: :thing, kind: :req, default_source: nil, type_hint: hint)

        expect { builder.send(:refuse_unresolvable_model_param!, param) }
          .not_to raise_error, "refused a #{hint}"
      end
    end

    it "does not fire for a parameter that has its own default" do
      builder = Pinspec::Setup::ContextBuilder.new(target: target("order_summary.rb"), profile: profile)
      param = Pinspec::Param.new(name: :distributor, kind: :opt,
                                 default_source: "Distributor.default", type_hint: "Distributor")

      expect { builder.send(:refuse_unresolvable_model_param!, param) }.not_to raise_error
    end

    it "does not fire when a schema column of that name can type the parameter" do
      builder = Pinspec::Setup::ContextBuilder.new(target: target("order_summary.rb"), profile: profile)
      param = Pinspec::Param.new(name: :email, kind: :req, default_source: nil, type_hint: "Email")

      expect(Pinspec::Setup::ContextBuilder::NON_MODEL_HINTS).not_to include("Email")
      expect(builder.send(:unambiguous_column_for, :email)).not_to be_nil
      expect { builder.send(:refuse_unresolvable_model_param!, param) }.not_to raise_error
    end

    it "does not fire for a splat" do
      builder = Pinspec::Setup::ContextBuilder.new(target: target("order_summary.rb"), profile: profile)
      param = Pinspec::Param.new(name: :extras, kind: :rest, default_source: nil, type_hint: "Extra")

      expect { builder.send(:refuse_unresolvable_model_param!, param) }.not_to raise_error
    end
  end

  describe "emitting into a suite with no rails_helper" do
    it "requires the helper the app actually has" do
      writer = Pinspec::Emit::SpecWriter.new(
        app_root: app, target: target("order_summary.rb"), plan: nil, corpus: nil,
        stability: nil, fk_map: {}
      )

      expect(writer.send(:suite_helper)).to eq("spec_helper")
    end
  end
end
