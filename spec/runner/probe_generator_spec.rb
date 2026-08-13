# frozen_string_literal: true

# M-07's generator, tested without booting anything. The integration spec runs the
# result for real; these examples guard the properties that make running generated
# code inside someone else's application defensible in the first place.
RSpec.describe Pinspec::Runner::ProbeGenerator do
  def parts(app = "rails71_basic", service = "invoice_calculator.rb", method = "call")
    root    = File.expand_path("../fixtures/apps/#{app}", __dir__)
    target  = Pinspec::Analyzer::TargetParser.parse(File.join(root, "app/services", service), method)
    profile = Pinspec::Analyzer::AppProfileReader.read(root)
    plan    = Pinspec::Setup::ContextBuilder.build(target: target, profile: profile)
    corpus  = Pinspec::Inputs::Corpus.build(target: target, plan: plan, schema: profile.schema, max_cases: 3)

    [target, plan, corpus, profile]
  end

  subject(:probe) do
    target, plan, corpus, profile = parts

    described_class.generate(plan: plan, corpus: corpus, fk_map: profile.schema.fk_map, target: target)
  end

  # Comments are not code, and the serializer's own header says "no filter_map".
  let(:code_only) do
    probe.lines.reject { |line| line.strip.start_with?("#") }.join
  end

  describe "what makes it safe to run in someone else's app" do
    it "requires only the standard library and libraries the app already owns" do
      requires = probe.scan(/^\s*require ["']([^"']+)["']/).flatten

      # The contract is "pinspec adds no gem to a client's Gemfile", not "the probe
      # requires nothing". factory_bot is the app's own gem and is loaded only because
      # a real app bundles it with `require: false` and requires it from its spec
      # helper - which `rails runner` never reads, so a plan built on 113 factories
      # would otherwise report that the app has none.
      app_owned = %w[factory_bot factory_girl]

      expect(requires - app_owned).to contain_exactly("json", "active_support/testing/time_helpers")
      expect(requires & app_owned).not_to be_empty
    end

    it "loads the app's factory library defensively, so a missing one is still a clean error" do
      expect(probe).to include("rescue LoadError")
      expect(probe).to include("factory_bot could not be loaded")
    end

    it "refuses to run outside RAILS_ENV=test" do
      expect(probe).to include("refusing to run outside RAILS_ENV=test")
      expect(probe).to include('ENV["PINSPEC_UNSAFE"] == "1"')
    end

    it "refuses to run where ActiveRecord is not loaded" do
      expect(probe).to include("ActiveRecord is not loaded")
    end

    it "rolls every case back" do
      expect(probe).to include("raise ActiveRecord::Rollback")
      expect(probe).to include("transaction(requires_new: true)")
    end

    it "can be read before it is run" do
      # Nothing is eval'd from a string and nothing is fetched: the whole payload
      # is inline JSON in the file.
      expect(code_only).not_to match(/\beval\b/)
      expect(code_only).not_to match(/Net::HTTP|open-uri|system\(|`/)
    end
  end

  describe "one serializer, two hosts" do
    it "embeds templates/serializer.rb verbatim" do
      # M-09 writes this same file into the emitted spec. A copy that drifted would
      # be the bug class section 4c exists to prevent.
      expect(probe).to include(described_class.serializer_source)
    end

    it "carries the serializer version the CLI is using" do
      expect(probe).to include("\"serializer\": #{Pinspec::SERIALIZER_VERSION}")
    end
  end

  describe "the payload" do
    subject(:payload) do
      target, plan, corpus, profile = parts

      described_class.new(plan: plan, corpus: corpus, fk_map: profile.schema.fk_map, target: target).payload
    end

    it "ships the fk_map, without which the probe cannot tell a key from a quantity" do
      expect(payload["fk_map"]).to include("invoices.customer_id" => "customers")
    end

    it "ships the plan, the cases, and the isolation regime" do
      expect(payload["setup_plan"].map { |step| step["kind"] }).to include("freeze_time", "create_record")
      expect(payload["cases"].size).to eq(3)
      expect(payload["isolation"]).to eq("transaction")
    end

    it "ships the target's construction kind, so the subject is built the same way" do
      expect(payload["target"]).to include("class" => "InvoiceCalculator", "construction" => "new")
    end

    it "is JSON, because that is the boundary" do
      require "json"

      expect { JSON.parse(JSON.generate(payload)) }.not_to raise_error
    end
  end

  describe "the SQL filters that would otherwise make everything unstable" do
    it "drops SCHEMA and TRANSACTION notifications" do
      # Rails logs column introspection once per model per process, so the first
      # case to touch a model would diverge from every later one.
      expect(probe).to include('%w[SCHEMA TRANSACTION].include?(payload[:name].to_s)')
    end

    it "drops query-cache hits" do
      expect(probe).to include("payload[:cached]")
    end

    it "detects a target that escaped its transaction" do
      expect(probe).to include("PINSPEC_BREACH")
      expect(probe).to include("escaped_transaction")
    end
  end

  describe "side effects" do
    it "forces the test adapters, so a setup callback cannot reach a real queue" do
      expect(probe).to include("ActiveJob::Base.queue_adapter = :test")
      expect(probe).to include("ActionMailer::Base.delivery_method = :test")
    end

    it "clears the sinks after setup and before the target" do
      # Setup noise must never be attributed to the target: a factory's
      # after(:create) enqueues too.
      clear = probe.lines.each_index.select { |i| probe.lines[i].strip == "pinspec_clear_sinks" }
      # The call site, not the definition - `def pinspec_invoke(subject` appears
      # earlier in the file than either.
      invoke = probe.lines.index do |line|
        line.include?("pinspec_invoke(subject") && !line.strip.start_with?("def ")
      end

      expect(clear).not_to be_empty
      expect(invoke).not_to be_nil
      expect(clear.any? { |index| index < invoke }).to be(true)
    end

    it "forwards keyword arguments through one shim" do
      # Empty-keyword-splat forwarding differs before Ruby 2.7, and open-coding it
      # at each call site is how that bites.
      expect(probe.scan(/def pinspec_invoke/).size).to eq(1)
    end
  end

  describe "the Ruby 2.6 syntax floor" do
    # The probe runs in the app's Ruby, not pinspec's.
    it "parses on 2.6" do
      ruby26 = File.expand_path("~/.rvm/rubies/ruby-2.6.4/bin/ruby")
      skip "no Ruby 2.6 available to check against" unless File.executable?(ruby26)

      require "open3"
      require "tempfile"

      Tempfile.create(["pinspec_probe", ".rb"]) do |file|
        file.write(probe)
        file.flush

        _out, err, status = Open3.capture3(ruby26, "-c", file.path)
        expect(status.success?).to be(true), "probe does not parse on Ruby 2.6:\n#{err}"
      end
    end

    it "avoids syntax Ruby 2.6 cannot parse" do
      expect(code_only).not_to match(/\bfilter_map\b/)
      expect(code_only).not_to match(/^\s*def \w+\(.*\) = /) # endless method
    end
  end
end
