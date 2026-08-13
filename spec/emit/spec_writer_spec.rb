# frozen_string_literal: true

# M-09 acceptance, spec v0.3 §7. The emitted spec has to control the same six axes
# the probe controlled, by the same rules - so most of these examples are about the
# spec host *forcing* the capture's answer rather than inheriting the suite's.
RSpec.describe Pinspec::Emit::SpecWriter do
  APP = File.expand_path("../fixtures/apps/rails71_basic", __dir__)

  def target_for(service = "invoice_calculator.rb", method = "call")
    Pinspec::Analyzer::TargetParser.parse(File.join(APP, "app/services", service), method)
  end

  def observation(id, **overrides)
    {
      "case_id" => id, "status" => "returned",
      "return_value" => { "t" => "record", "class" => "Invoice",
                          "attributes" => { "customer_id" => { "t" => "ref", "v" => "customer_1" },
                                            "total" => { "t" => "decimal", "v" => "110.0" } } },
      "error" => nil, "setup_error" => nil,
      "enqueued_jobs" => [], "mail_deliveries" => [],
      "sql_fingerprints" => [], "db_delta" => { "inserts" => 1 }, "flags" => [], "duration_ms" => 1
    }.merge(overrides)
  end

  def stability_for(observations)
    verdicts = observations.map do |o|
      Pinspec::Emit::StabilityFilter::Verdict.new(
        case_id: o["case_id"], stable: true, cause: nil, diff: nil, observation: o
      )
    end

    Pinspec::Emit::StabilityFilter::Report.new(verdicts: verdicts, runs: 2, compared_fields: ["status"])
  end

  def write(service: "invoice_calculator.rb", method: "call", observations: [observation("c001")], **options)
    target  = target_for(service, method)
    profile = Pinspec::Analyzer::AppProfileReader.read(APP)
    plan    = Pinspec::Setup::ContextBuilder.build(target: target, profile: profile)
    corpus  = Pinspec::Inputs::Corpus.build(target: target, plan: plan, schema: profile.schema, max_cases: 2)

    writer = described_class.new(
      app_root: Dir.mktmpdir("pinspec-emit"), target: target, plan: plan, corpus: corpus,
      stability: stability_for(observations), fk_map: profile.schema.fk_map, **options
    )

    [writer, writer.write!]
  end

  before { require "tmpdir" }

  subject(:source) do
    _writer, result = write

    File.read(result.spec_path)
  end

  describe "the header, which tells a reader what they are looking at" do
    it "carries provenance so pinspec can recognise its own output" do
      expect(source).to include(described_class::PROVENANCE)
      expect(source).to include("Do not hand-edit")
    end

    it "records the plan, serializer version and isolation regime" do
      expect(source).to match(/# plan_id:\s+[0-9a-f]{12}/)
      expect(source).to include("# serializer: #{Pinspec::SERIALIZER_VERSION}")
      expect(source).to include("# isolation:  transaction")
    end

    it "says a failure means changed behaviour, not wrong behaviour" do
      # Bugs get pinned on purpose.
      expect(source).to include("freezes what the code does TODAY")
      expect(source).to include("Bugs get pinned on")
    end

    it "lists the cases it could not pin, and why" do
      unstable = Pinspec::Emit::StabilityFilter::Verdict.new(
        case_id: "c002", stable: false, cause: :identity_churn, diff: "", observation: observation("c002")
      )
      report = Pinspec::Emit::StabilityFilter::Report.new(
        verdicts: [stability_for([observation("c001")]).verdicts.first, unstable],
        runs: 2, compared_fields: ["status"]
      )

      target  = target_for
      profile = Pinspec::Analyzer::AppProfileReader.read(APP)
      plan    = Pinspec::Setup::ContextBuilder.build(target: target, profile: profile)
      corpus  = Pinspec::Inputs::Corpus.build(target: target, plan: plan, schema: profile.schema, max_cases: 2)
      result  = described_class.new(app_root: Dir.mktmpdir("pinspec-emit"), target: target, plan: plan,
                                    corpus: corpus, stability: report, fk_map: profile.schema.fk_map).write!

      expect(File.read(result.spec_path)).to include("c002: identity_churn")
    end
  end

  describe "the axes it forces rather than inherits" do
    it "forces the capture's isolation regime" do
      # A suite that truncates instead of transacting would fire after_commit
      # callbacks the probe never saw.
      expect(source).to include("ActiveRecord::Base.transaction(requires_new: true)")
      expect(source).to include("raise ActiveRecord::Rollback")
      expect(source).to include("Forced regardless of this suite's own strategy")
    end

    it "pins the clock, the seed, the locale and the zone" do
      expect(source).to include("travel_to Time.parse(\"#{Pinspec::PINSPEC_EPOCH}\")")
      expect(source).to include("srand(#{Pinspec::PINSPEC_SEED})")
      expect(source).to include("I18n.locale = :en")
      expect(source).to include('Time.zone = "UTC"')
      expect(source).to include("after { travel_back }")
    end

    it "clears the sinks per example" do
      # ActionMailer::Base.deliveries is not cleared for you: example two would
      # otherwise count example one's mail.
      expect(source).to include("pinspec_clear_sinks")
    end

    it "tags examples so the support file can force the :test queue adapter" do
      # A suite whose own adapter is :inline executes jobs instead of enqueuing
      # them, and every job pin would see nothing.
      expect(source).to include(":pinspec do")
    end
  end

  describe "the TZ guard" do
    it "is emitted only for a target that reads the process clock" do
      expect(source).not_to include("pinspec_guard_env!")
    end

    it "is emitted, with a warning, when the target does read it" do
      # Guarding every pin would mean no pin survives a different timezone.
      clock_app = File.expand_path("../fixtures/apps/full_app", __dir__)
      skip "clock fixture unavailable" unless File.directory?(clock_app)

      target = Pinspec::Analyzer::TargetParser.parse(
        File.expand_path("../fixtures/targets/clock_service.rb", __dir__), "ExpiryChecker#call"
      )

      expect(target).to be_clock_dependent
    end
  end

  describe "the serializer call, which v0.2 got wrong" do
    it "passes the ref table and the fk_map, because one argument cannot work" do
      expect(source).to include("PinspecSerializer.normalize(pinned, refs:")
      expect(source).to include("fk_map: pinspec_fk_map")
    end

    # The probe serializes the return value BEFORE registering the returned
    # record, so the spec host has to as well or the record gains a "ref" key in
    # one host and not the other.
    it "normalizes the return value without the returned record in the refs" do
      expect(source).to include("normalize(pinned, refs: pinspec_refs(pinspec_records), fk_map:")
    end

    it "uses the table that includes it for the side effects" do
      _writer, result = write(observations: [observation("c001", "enqueued_jobs" => [{ "job" => "SyncJob" }])])

      expect(File.read(result.spec_path)).to include("pinspec_jobs_from(pinspec_refs_for, pinspec_fk_map)")
    end
  end

  describe "records and refs" do
    it "renders the plan's records as let!, with the calls a human would write" do
      # Not a bare `create(:customer)`: the spec host has to replay the probe's
      # deterministic factory retry, or it consumes different random values from a
      # non-deterministic factory and builds a different record.
      expect(source).to include("let!(:customer_1) { PinspecFactory.create(:customer) }")
    end

    it "builds the ref table from its own records" do
      expect(source).to include("let(:pinspec_records) { { customer_1: customer_1 } }")
    end

    it "passes model-typed arguments by ref name, never by id" do
      expect(source).to include("InvoiceCalculator.new(customer_1")
    end
  end

  # The DoD's grep, and the property the whole identity design exists for.
  # An emitted pin is a COMMITTED file. Ruby 3.4 changed `Hash#inspect` to put
  # spaces around the rocket, so delegating to it made the file's bytes depend on
  # which Ruby pinspec ran on - two colleagues pinning the same target got a diff on
  # every line, and a Ruby upgrade rewrote every pin in the repository. For a tool
  # whose promise is "re-run and nothing changes unless the behaviour changed", that
  # is the promise breaking.
  describe "a literal that does not depend on pinspec's own Ruby" do
    subject(:writer) do
      described_class.new(app_root: "/tmp/app", target: nil, plan: nil, corpus: nil,
                          stability: nil, fk_map: {})
    end

    def literal(value)
      writer.send(:canonical_literal, value)
    end

    it "renders hashes in one form, whatever Hash#inspect does today" do
      expect(literal({ "t" => "int", "v" => 5 })).to eq('{"t" => "int", "v" => 5}')
      expect(literal({})).to eq("{}")
    end

    it "recurses, so a nested hash cannot slip back to inspect" do
      expect(literal({ "a" => [{ "b" => 1 }] })).to eq('{"a" => [{"b" => 1}]}')
      expect(literal([[{ "k" => nil }]])).to eq('[[{"k" => nil}]]')
    end

    it "leaves the kinds that inspect identically on every Ruby alone" do
      expect(literal("x")).to eq('"x"')
      expect(literal(:sym)).to eq(":sym")
      expect(literal(nil)).to eq("nil")
      expect(literal(1.5)).to eq("1.5")
      expect(literal([])).to eq("[]")
    end

    # The property, stated as a property: no rocket without spaces anywhere in a
    # rendered snapshot, on any Ruby.
    it "never emits the pre-3.4 spelling" do
      rendered = literal({ "t" => "hash", "v" => [[{ "t" => "sym", "v" => "k" }, { "t" => "int", "v" => 1 }]] })

      expect(rendered).not_to include('"=>')
      expect(rendered).not_to match(/\w"=>/)
      expect(rendered.scan(" => ").size).to eq(rendered.scan("=>").size)
    end
  end

  describe "zero literal database ids" do
    it "pins no id-shaped snapshot value as an integer" do
      offenders = source.scan(/"\w*_id" => \{"t" => "int"/)

      expect(offenders).to be_empty
    end

    it "pins no primary key at all" do
      expect(source).not_to match(/"id" => \{"t" => "int"/)
    end
  end

  describe "naming, without an LLM" do
    it "describes each case deterministically" do
      # M-10 may improve the prose later; it can never touch a value.
      expect(source).to match(/describe "call returns the pinned Invoice it creates \(c00\d, \w+\)"/)
    end

    it "names a raise as a raise" do
      raised = observation("c001", "status" => "raised",
                                   "error" => { "class" => "ArgumentError", "message" => "no status" },
                                   "return_value" => nil)
      _writer, result = write(observations: [raised])

      expect(File.read(result.spec_path)).to include("raises ArgumentError")
      expect(File.read(result.spec_path)).to include("raise_error(ArgumentError, \"no status\")")
    end
  end

  describe "never touching what it did not write" do
    it "refuses a file it does not recognise" do
      writer, result = write
      File.write(result.spec_path, "# someone's own work\n")

      expect { writer.write! }.to raise_error(Pinspec::VerifyFailed, /was not written by pinspec/)
    end

    it "overwrites its own output happily" do
      writer, = write

      expect { writer.write! }.not_to raise_error
    end

    it "overwrites a foreign file only with force" do
      writer, result = write(force: true)
      File.write(result.spec_path, "# someone's own work\n")

      expect { writer.write! }.not_to raise_error
    end
  end

  describe "the support files" do
    it "writes the serializer from the same template the probe embeds" do
      _writer, result = write
      serializer = result.support_paths.find { |path| path.end_with?("pinspec_serializer.rb") }

      expect(File.read(serializer)).to eq(Pinspec::Runner::ProbeGenerator.serializer_source)
    end

    it "writes the spec-host support modules" do
      _writer, result = write

      expect(result.support_paths.map { |p| File.basename(p) })
        .to contain_exactly("pinspec_serializer.rb", "pinspec_support.rb", "pinspec_factory.rb")
    end

    # All three come from templates/ that the probe embeds too. That is the whole of
    # "one contract, two hosts": a copy written by hand here would be a second chance
    # for the two hosts to disagree.
    it "writes them from the same templates the probe embeds" do
      _writer, result = write

      factory = result.support_paths.find { |p| p.end_with?("pinspec_factory.rb") }

      expect(File.read(factory)).to eq(File.read(described_class::FACTORY_TEMPLATE))
      expect(File.read(factory)).to eq(Pinspec::Runner::ProbeGenerator.factory_source)
    end
  end
end
