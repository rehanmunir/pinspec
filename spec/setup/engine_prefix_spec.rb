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

  def profile_for_app
    profile
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

  # M-16. A class with no #initialize has the DEFAULT constructor, not an unreadable
  # one. Measured across five public Rails codebases, refusing this shape cost 88% of
  # mastodon's service directory and 100% of publishing-api's inheritance cases.
  describe "a constructor that lives in another file, or nowhere" do
    before { Pinspec::Analyzer::TargetParser.reset_application_cache! }

    it "reads a superclass constructor out of the file that defines it" do
      profile = target("inheriting_summary.rb")

      expect(profile.construction_kind).to eq(:new)
      expect(profile.initializer_params.map(&:name)).to eq(%i[order actor])
      expect(profile.construction_source).to eq(:inherited)
    end

    # The mastodon shape: no constructor anywhere, dependencies as method arguments.
    it "assumes a zero-argument constructor when no ancestor defines one" do
      profile = target("argument_taking_service.rb")

      expect(profile.construction_kind).to eq(:new)
      expect(profile.initializer_params).to be_empty
      expect(profile.params.map(&:name)).to eq([:order])
    end

    # The assumption is unverified once the chain leaves the application, and says so
    # rather than presenting a guess as a reading.
    it "distinguishes a constructor it read from one it assumed" do
      expect(target("inheriting_summary.rb").construction_source).to eq(:inherited)
      expect(target("argument_taking_service.rb").construction_source).to eq(:assumed)
      expect(target("order_summary.rb").construction_source).to eq(:own)
    end

    it "still plans a world for the inherited constructor's parameters" do
      profile = target("inheriting_summary.rb")
      plan = Pinspec::Setup::ContextBuilder.build(target: profile, profile: profile_for_app)

      expect(plan.bindings[:order]).to eq("shop_order_1")
    end

    it "does not read a class the application does not own" do
      # BaseHandler is referenced but defined nowhere under app/ or lib/, so it is
      # out of reach by design - pinspec will not read a gem's source.
      expect(Pinspec::Analyzer::TargetParser.new(
        File.join(app, "app/services/argument_taking_service.rb"), "call"
      ).send(:scope_from_application, "BaseHandler")).to be_nil
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

      Pinspec::Setup::ContextBuilder::NON_MODEL_HINTS.each do |hint|
        param = Pinspec::Param.new(name: :thing, kind: :req, default_source: nil, type_hint: hint)

        expect { builder.send(:refuse_unresolvable_model_param!, param) }
          .not_to raise_error, "refused a #{hint}"
      end
    end

    # The list is ten entries because those are the only hints the parser ever
    # produces. Names like `params` or `status` never reach it: they are turned into
    # Hash or into no hint at all before anything camelizes them. Every entry on that
    # list also has a Boundary value, so exempting one can never mean passing nil.
    it "exempts only hints the parser can actually produce, all of which have values" do
      %w[params create_params options status limit].each do |name|
        hint = Pinspec::Analyzer::TargetParser.allocate.send(:type_hint_for, name, :req, nil)

        expect(hint).to satisfy { |h| h.nil? || Pinspec::Setup::ContextBuilder::NON_MODEL_HINTS.include?(h) },
                        "#{name} produced #{hint.inspect}, which is neither nil nor an exempt hint"
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
