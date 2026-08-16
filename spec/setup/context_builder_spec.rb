# frozen_string_literal: true

RSpec.describe Pinspec::Setup::ContextBuilder do
  def app_root(app)
    File.expand_path("../fixtures/apps/#{app}", __dir__)
  end

  def build(app, service, method = "call", **options)
    root   = app_root(app)
    target = Pinspec::Analyzer::TargetParser.parse(File.join(root, "app/services", service), method)

    described_class.build(
      target:  target,
      profile: Pinspec::Analyzer::AppProfileReader.read(root),
      **options
    )
  end

  def step_kinds(plan)
    plan.steps.map(&:kind)
  end

  def record(plan, ref)
    plan.record_steps.find { |step| step.payload[:name] == ref }
  end

  describe "the environment every plan pins (rule 7)" do
    subject(:plan) { build("basic_app", "invoice_calculator.rb") }

    it "freezes the clock and seeds randomness before anything is created" do
      expect(step_kinds(plan).first(4)).to eq(%i[freeze_time seed_random set_locale set_zone])
      expect(plan.steps.first.payload[:at]).to eq(Pinspec::PINSPEC_EPOCH)
      expect(plan.steps[1].payload[:seed]).to eq(Pinspec::PINSPEC_SEED)
    end

    it "pins the locale and zone from the app profile" do
      expect(plan.steps_of(:set_locale).first.payload[:locale]).to eq(:en)
      expect(plan.steps_of(:set_zone).first.payload[:zone]).to eq("UTC")

      german = build("full_app", "company_auditor.rb")
      expect(german.steps_of(:set_locale).first.payload[:locale]).to eq(:de)
    end

    it "carries the app's isolation regime onto the plan (rule 13)" do
      expect(plan.isolation).to eq(:transaction)
      expect(build("full_app", "company_auditor.rb").isolation).to eq(:truncation)
    end

    it "stamps an env fingerprint for the emitted spec's TZ guard (rule 14)" do
      expect(plan.env_fingerprint).to include(
        locale: :en, zone: "UTC", serializer: Pinspec::SERIALIZER_VERSION
      )
      expect(plan.env_fingerprint[:rails]).to eq("7.1.3.2")
    end

    it "records the timezone the probe will use, not this shell's" do
      expect(plan.env_fingerprint[:tz]).to eq(Pinspec::Runner::Sandbox::FORCED_ENV.fetch("TZ"))
    end

    it "produces the same plan_id whatever TZ the operator's shell is set to" do
      original = ENV.fetch("TZ", nil)

      ENV["TZ"] = "Asia/Karachi"
      karachi = build("basic_app", "invoice_calculator.rb")
      ENV["TZ"] = "Etc/GMT+8"
      elsewhere = build("basic_app", "invoice_calculator.rb")

      expect(karachi.plan_id).to eq(elsewhere.plan_id)
      expect(karachi.env_fingerprint).to eq(elsewhere.env_fingerprint)
    ensure
      original.nil? ? ENV.delete("TZ") : ENV["TZ"] = original
    end

    it "follows an explicit override" do
      overridden = Pinspec::Setup::ContextBuilder.build(
        target: Pinspec::Analyzer::TargetParser.parse(
          File.expand_path("../fixtures/apps/basic_app/app/services/invoice_calculator.rb", __dir__), "call"
        ),
        profile: Pinspec::Analyzer::AppProfileReader.read(
          File.expand_path("../fixtures/apps/basic_app", __dir__)
        ),
        tz: "Asia/Tokyo"
      )

      expect(overridden.env_fingerprint[:tz]).to eq("Asia/Tokyo")
      expect(overridden.plan_id).not_to eq(plan.plan_id)
    end
  end

  describe "records for model-typed parameters (rules 1, 2, 3)" do
    it "uses a factory when one exists, and lets it own its associations" do
      plan = build("basic_app", "invoice_calculator.rb")
      step = record(plan, "invoice_1")

      expect(step.payload[:factory]).to eq(:invoice)
      expect(step.payload[:model]).to eq("Invoice")
      expect(plan.record_steps.map { |s| s.payload[:name] }).to eq(["invoice_1"])
    end

    it "builds the required belongs_to closure when there is no factory" do
      plan = build("full_app", "company_auditor.rb")
      step = record(plan, "company_1")

      expect(step.payload[:factory]).to be_nil
      expect(step.payload[:model]).to eq("Company")
    end

    it "fills every NOT NULL column that no association satisfies" do
      step = record(build("full_app", "company_auditor.rb"), "company_1")

      expect(step.payload[:attrs].keys).to eq(["name"])
      expect(step.payload[:attrs]).not_to have_key("id")
    end

    it "wires a required parent through assoc_refs, parent first" do
      plan = build("full_app", "contract_reviewer.rb")
      step = record(plan, "contract_1")

      expect(step.payload[:assoc_refs]).to eq("company_id" => "company_1")

      names = plan.steps.map { |s| s.payload[:name] }
      expect(names.index("company_1")).to be < names.index("contract_1")
    end

    it "leaves nullable associations null, building the smallest world that exists" do
      plan = build("full_app", "contract_reviewer.rb")

      expect(plan.record_steps.map { |s| s.payload[:model] }).not_to include("Warehouse")
      expect(record(plan, "contract_1").payload[:assoc_refs]).not_to have_key("warehouse_id")
    end

    it "fills temporal columns from the plan's frozen clock" do
      attrs = record(build("full_app", "contract_reviewer.rb"), "contract_1").payload[:attrs]

      expect(attrs["signed_at"]).to eq(Pinspec::PINSPEC_EPOCH)
      expect(attrs["starts_on"]).to eq("2026-01-01")
    end

    it "respects a column's length limit" do
      attrs = record(build("full_app", "contract_reviewer.rb"), "contract_1").payload[:attrs]

      expect(attrs["code"]).to eq("pins")
    end

    it "binds each parameter to the ref that satisfies it" do
      plan = build("basic_app", "invoice_calculator.rb")

      expect(plan.bindings).to eq(invoice: "invoice_1")
      expect(plan.binding_for(:invoice)).to eq("invoice_1")
      expect(plan.bindings).not_to have_key(:tax_rate)
    end

    it "gives two parameters of the same model two different records" do
      plan = build("full_app", "company_merger.rb")

      expect(plan.bindings).to eq(source_company: "company_1", target_company: "company_2")
      expect(record(plan, "company_1")).not_to be_nil
      expect(record(plan, "company_2")).not_to be_nil
    end

    it "resolves a qualified parameter name to its model" do
      plan = build("full_app", "company_merger.rb")

      expect(record(plan, "company_1").payload[:model]).to eq("Company")
    end

    it "creates nothing for a target whose parameters are all scalars" do
      plan = build("basic_app", "customer_report.rb", "Reports::CustomerReport.call")

      expect(plan.record_steps).to be_empty
      expect(plan.bindings).to be_empty
    end
  end

  describe "uniqueness (rule 4)" do
    subject(:plan) { build("full_app", "company_merger.rb") }

    it "suffixes a unique column deterministically, namespaced by generation" do
      expect(record(plan, "company_1").payload[:attrs]["name"]).to eq("pinspec-p1-1")
      expect(record(plan, "company_2").payload[:attrs]["name"]).to eq("pinspec-p1-2")
    end

    it "changes the namespace on a re-plan, so a collision cannot repeat" do
      regenerated = build("full_app", "company_merger.rb", generation: 2)

      expect(record(regenerated, "company_1").payload[:attrs]["name"]).to eq("pinspec-p2-1")
      expect(regenerated.generation).to eq(2)
    end

    it "leaves a non-unique column unsuffixed" do
      with_person = build("full_app", "company_reviewer.rb")

      expect(record(with_person, "person_1").payload[:attrs]["full_name"]).to eq("pinspec")
    end
  end

  describe "context steps, which all point at a record (rules 5, 6, 10)" do
    subject(:plan) { build("full_app", "company_auditor.rb") }

    it "sets the tenant, reusing a record already in the plan" do
      step = plan.steps_of(:set_tenant).first

      expect(step.payload[:record_ref]).to eq("company_1")
    end

    describe "a target that reads the current user" do
      subject(:plan) { build("full_app", "company_reviewer.rb") }

      it "stubs the current user for a devise app" do
        step = plan.steps_of(:stub_current).first

        expect(step.payload[:kind]).to eq(:devise_user)
        expect(step.payload[:record_ref]).to eq("person_1")
      end

      it "sets paper_trail's whodunnit, because an unset one is a null that drifts" do
        expect(plan.steps_of(:set_whodunnit).first.payload[:record_ref]).to eq("person_1")
      end

      it "shares one user record between auth and whodunnit" do
        expect(plan.record_steps.count { |s| s.payload[:model] == "Person" }).to eq(1)
      end
    end

    describe "a target that does not" do
      it "builds no user, and says so rather than leaving a reader to notice" do
        expect(plan.steps_of(:stub_current)).to be_empty
        expect(plan.steps_of(:set_whodunnit)).to be_empty
        expect(plan.record_steps.map { |s| s.payload[:model] }).not_to include("Person")
      end

      it "names the honest limit: a callee that reads one is invisible here" do
        kinds = plan.notes.map { |note| note[:kind] }

        expect(kinds).to include(:current_user_not_built, :whodunnit_unset)
        expect(plan.notes.find { |n| n[:kind] == :current_user_not_built }[:detail])
          .to include("transitive callee")
      end

      it "reports each note once" do
        kinds = plan.notes.map { |note| note[:kind] }

        expect(kinds).to eq(kinds.uniq)
      end

      it "still reports the authorization library, which is a separate fact" do
        expect(plan.notes.map { |note| note[:kind] }).to include(:authz_present)
      end
    end

    it "orders every context step after the record it references" do
      names = plan.steps.map { |s| s.payload[:name] }.compact
      refs  = plan.steps.each_with_index.filter_map do |step, index|
        [step.payload[:record_ref], index] if step.payload[:record_ref]
      end

      refs.each do |ref, index|
        creation = plan.steps.index { |s| s.payload[:name] == ref }
        expect(creation).not_to be_nil, "#{ref} is referenced but never created"
        expect(creation).to be < index
      end

      expect(names).not_to be_empty
    end

    it "notes an authorization library rather than bypassing it" do
      expect(plan.notes.map { |n| n[:kind] }).to include(:authz_present)
    end

    it "adds no context steps for an app with none of it" do
      plain = build("basic_app", "invoice_calculator.rb")

      expect(step_kinds(plain)).not_to include(:set_tenant, :stub_current, :set_whodunnit)
    end
  end

  describe "feature flags (rule 9)" do
    it "pins every flag the target names, explicitly off" do
      plan = build("full_app", "company_auditor.rb")
      step = plan.steps_of(:set_flag).first

      expect(step.payload[:flag]).to eq(:audit_v2)
      expect(step.payload[:enabled]).to be(false)
    end

    it "pins no flags for an app without flipper" do
      expect(build("basic_app", "invoice_calculator.rb").steps_of(:set_flag)).to be_empty
    end
  end

  describe "subject construction (rule 12, row 29)" do
    it "emits the class and how to build it, but not the argument values" do
      step = build("basic_app", "invoice_calculator.rb").subject_step

      expect(step.payload[:class]).to eq("InvoiceCalculator")
      expect(step.payload[:kind]).to eq(:new)
      expect(step.payload[:params]).to eq(%i[invoice tax_rate])
      expect(step.payload).not_to have_key(:args)
    end

    it "emits no subject step for a class-method target" do
      plan = build("basic_app", "customer_report.rb", "Reports::CustomerReport.call")

      expect(plan.subject_step).to be_nil
    end

    it "puts the subject last, after everything it might need" do
      expect(step_kinds(build("basic_app", "invoice_calculator.rb")).last).to eq(:construct_subject)
    end
  end

  describe "plan_id" do
    it "is content-addressed, so the same target always yields the same plan" do
      expect(build("basic_app", "invoice_calculator.rb").plan_id)
        .to eq(build("basic_app", "invoice_calculator.rb").plan_id)
    end

    it "differs between targets" do
      expect(build("basic_app", "invoice_calculator.rb").plan_id)
        .not_to eq(build("full_app", "company_auditor.rb").plan_id)
    end

    it "differs between generations even when nothing else changes" do
      one = build("basic_app", "invoice_calculator.rb")
      two = build("basic_app", "invoice_calculator.rb", generation: 2)

      expect(one.steps).to eq(two.steps)
      expect(one.plan_id).not_to eq(two.plan_id)
    end
  end

  describe "refusals: naming the wall instead of hanging on it" do
    it "refuses ros-apartment, which switches schemas per tenant (rule 5)" do
      expect { build("oddities_app", "statement_builder.rb") }
        .to raise_error(Pinspec::UnresolvableSetup) { |error|
          expect(error.reason).to eq(:apartment)
          expect(error.exit_code).to eq(5)
          expect(error.message).to include("ros-apartment")
        }
    end

    it "refuses a NOT NULL column whose type it cannot honestly fill" do
      expect { build("full_app", "order_archiver.rb") }
        .to raise_error(Pinspec::UnresolvableSetup) { |error|
          expect(error.reason).to eq(:unknown_column_type)
          expect(error.message).to include("orders.service_area")
          expect(error.message).to include("geography")
        }
    end

    it "refuses two tables that require each other, naming the path" do
      expect { build("cycle_app", "knot.rb", "Knot#call") }
        .to raise_error(Pinspec::UnresolvableSetup) { |error|
          expect(error.reason).to eq(:association_cycle)
          expect(error.message).to include("chickens")
          expect(error.message).to include("eggs")
          expect(error.message).to include("optional")
        }
    end

    it "refuses a NOT NULL foreign key to the table's own row" do
      expect { build("cycle_app", "knot.rb", "SelfKnot#call") }
        .to raise_error(Pinspec::UnresolvableSetup, /foreign key to itself/)
    end
  end

  describe "a factory that cannot found a world" do
    subject(:plan) { build("basic_app", "report_printer.rb") }

    it "falls back to the schema rather than using a factory that never persists" do
      step = record(plan, "report_1")

      expect(step.payload[:factory]).to be_nil
      expect(step.payload[:model]).to eq("Report")
      expect(step.payload[:attrs]).to eq("title" => "pinspec")
    end

    it "says why, so the fallback is not a silent surprise" do
      note = plan.notes.find { |n| n[:kind] == :factory_declined }

      expect(note[:detail]).to include("report_stub")
      expect(note[:detail]).to include("skip_create")
    end
  end

  describe "import clusters handed over by M-06" do
    let(:cluster) do
      Pinspec::ImportCluster.new(
        model: "Company", table: "companies", name: "imported_company_1",
        attrs: { "name" => Pinspec::Tags.encode("Acme") },
        source: "sample:companies:3f9a", redacted: [], flags: []
      )
    end

    # Imports come FIRST. create_record_for skips a table whose ref already exists, so
    # building factory rows first meant every binding pointed at the factory record
    # and the sampled row - the whole point of --sample - was never used.
    it "orders imports before created records, so bindings reach the sampled row" do
      plan = build("full_app", "company_auditor.rb", "call", imports: [cluster])
      step = plan.steps_of(:import_record).first

      expect(step.payload[:model]).to eq("Company")
      expect(step.payload[:name]).to eq("imported_company_1")
      expect(step.payload[:source]).to eq("sample:companies:3f9a")

      kinds = step_kinds(plan)
      expect(kinds.index(:import_record)).to be < (kinds.index(:create_record) || Float::INFINITY)
    end

    it "changes the plan_id, because it changes the world" do
      expect(build("full_app", "company_auditor.rb", "call", imports: [cluster]).plan_id)
        .not_to eq(build("full_app", "company_auditor.rb").plan_id)
    end
  end
end
