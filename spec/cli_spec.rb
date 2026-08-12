# frozen_string_literal: true

require "open3"

# The exit-code taxonomy (spec v0.3 §5.1) is a *CLI* contract: it is how a script
# tells "this target takes a block" from "this target doesn't exist". Asserting
# the constants in TargetParser's spec does not prove the binary honours them, so
# these examples shell out for real.
RSpec.describe "pinspec CLI" do
  ROOT = File.expand_path("..", __dir__)

  def run_cli(*args)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "pinspec"), *args
    )

    # capture3 tags output with the locale's external encoding, which is US-ASCII
    # when LANG is unset. Tag it UTF-8 so a stray non-ASCII byte fails the
    # assertion it belongs to rather than blowing up the matcher itself.
    [stdout.force_encoding("UTF-8"), stderr.force_encoding("UTF-8"), status]
  end

  def target(fixture, method)
    "spec/fixtures/targets/#{fixture}##{method}"
  end

  describe "version" do
    it "prints the version and the artifact versions, and exits 0" do
      stdout, _stderr, status = run_cli("version")

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("pinspec #{Pinspec::VERSION}")
      expect(stdout).to include("probe v#{Pinspec::PROBE_VERSION}")
      expect(stdout).to include("serializer v#{Pinspec::SERIALIZER_VERSION}")
    end
  end

  describe "plan" do
    it "prints the resolved target, including the constructor, and exits 0" do
      stdout, _stderr, status = run_cli("plan", target("invoice_calculator.rb", "call"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("InvoiceCalculator#call")
      expect(stdout).to include("InvoiceCalculator.new(invoice, tax_engine: TaxEngine.new")
      expect(stdout).to include("method params  (none)")
      expect(stdout).to include("SetupPlan generation lands in M2")
    end

    it "flags a clock-dependent target in the output, not just in the data" do
      stdout, _stderr, status = run_cli("plan", target("clock_service.rb", "ExpiryChecker#call"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("Time.now (line 9)")
      expect(stdout).to include("reads the process clock, not Time.zone")
    end

    # One example per refusal path, because a refusal that exits 0 or 1 is
    # indistinguishable from success or from a crash.
    {
      "a missing method"      => [["invoice_calculator.rb", "nope"], 2, /no method `nope`/],
      "an ambiguous name"     => [["ambiguous.rb", "call"], 3, /resolves to 2 definitions/],
      "a yielding method"     => [["block_service.rb", "each_invoice"], 4, /Blocks can't cross/],
      "an opaque constructor" => [["opaque_service.rb", "ContainerService#call"], 5, /reason: opaque_constructor/],
      "invalid Ruby"          => [["broken_source.txt", "call"], 1, /not valid Ruby/]
    }.each do |label, (args, code, matcher)|
      it "exits #{code} on #{label}" do
        _stdout, stderr, status = run_cli("plan", target(*args))

        expect(status.exitstatus).to eq(code)
        expect(stderr).to match(matcher)
      end
    end
  end

  describe "analyze" do
    def app(name)
      File.join(ROOT, "spec", "fixtures", "apps", name)
    end

    it "prints all three sections: app, schema, factories" do
      stdout, _stderr, status = run_cli("analyze", app("basic_app"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("app", "rails", "isolation")
      expect(stdout).to include("tables", "foreign keys")
      expect(stdout).to include("factories (FactoryBot)")
    end

    it "quotes the multi-database rollback warning verbatim, wrapped for a terminal" do
      stdout, _stderr, status = run_cli("analyze", app("full_app"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("warnings")
      # Wrapping breaks the text across lines, so compare on collapsed whitespace.
      expect(stdout.gsub(/\s+/, " ")).to include(Pinspec::MULTI_DB_ROLLBACK_WARNING.gsub(/\s+/, " "))
    end

    it "names model hazards with file and line" do
      stdout, = run_cli("analyze", app("full_app"))

      expect(stdout).to include("model hazards:")
      expect(stdout).to match(%r{after_commit: Order \(.*order\.rb:\d+\)})
    end

    it "exits 10 below the Rails floor, naming the missing APIs" do
      _stdout, stderr, status = run_cli("analyze", app("old_app"))

      expect(status.exitstatus).to eq(10)
      expect(stderr).to include("6.0 or newer")
      expect(stderr).to include("insert_all")
    end

    it "reports what it could not read rather than reporting nothing" do
      stdout, _stderr, status = run_cli("analyze", app("broken_app"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("could not read:")
      expect(stdout).to include("no_gemfile_lock")
    end

    it "names the legacy DSL, which changes what emitted specs will call" do
      stdout, _stderr, status = run_cli("analyze", app("legacy_app"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("factories (FactoryGirl)")
    end

    it "warns that an unreadable factory file will be treated as absent" do
      stdout, _stderr, status = run_cli("analyze", app("broken_app"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("unreadable factory files")
      expect(stdout).to include("broken.rb")
    end

    it "flags factories whose callbacks fire during setup" do
      stdout, _stderr, = run_cli("analyze", app("basic_app"))

      expect(stdout).to include("invoice: after(:create)")
      expect(stdout).to include("report_stub: skip_create")
    end

    it "exits 6 on a structure.sql app, with the workaround" do
      _stdout, stderr, status = run_cli("analyze", app("sql_app"))

      expect(status.exitstatus).to eq(6)
      expect(stderr).to include("db:schema:dump")
    end
  end

  describe "verbs that aren't built yet" do
    {
      "capture"  => ["M3", ["x.rb#call"]],
      "pin"      => ["M4", ["x.rb#call"]],
      "validate" => ["M5", ["spec/foo_spec.rb"]],
      "report"   => ["M5", []]
    }.each do |verb, (milestone, args)|
      it "says #{verb} lands in #{milestone} rather than pretending to work" do
        _stdout, stderr, status = run_cli(verb, *args)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("lands in #{milestone}")
      end
    end
  end
end
