# frozen_string_literal: true

require "open3"

RSpec.describe "pinspec CLI" do
  ROOT = File.expand_path("..", __dir__)

  def run_cli(*args)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "pinspec"), *args
    )

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
    def app_target(app, service, method = "call")
      root = File.join(ROOT, "spec", "fixtures", "apps", app)
      ["--app", root, "#{File.join(root, 'app/services', service)}##{method}"]
    end

    it "prints the resolved target and the plan that would build its world" do
      stdout, _stderr, status = run_cli("plan", *app_target("basic_app", "invoice_calculator.rb"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("InvoiceCalculator#call")
      expect(stdout).to include("InvoiceCalculator.new(invoice, tax_rate: 0.08)")
      expect(stdout).to include("setup plan")
      expect(stdout).to include("freeze_time 2026-01-01T12:00:00Z")
      expect(stdout).to include("create_record invoice_1 <- factory(:invoice)")
      expect(stdout).to include("invoice -> invoice_1")
    end

    it "shows the hazard-carrying app's plan: flags, tenant, truncation" do
      stdout, _stderr, status = run_cli("plan", *app_target("full_app", "company_auditor.rb"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("isolation truncation")
      expect(stdout).to include("set_flag :audit_v2 = false")
      expect(stdout).to include("set_tenant company_1")

      expect(stdout).not_to include("set_whodunnit")
      expect(stdout).to include("current_user_not_built")
    end

    it "shows the whodunnit step for a target that does read the current user" do
      stdout, _stderr, status = run_cli("plan", *app_target("full_app", "company_reviewer.rb"))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("stub_current devise_user person_1")
      expect(stdout).to include("set_whodunnit person_1")
    end

    it "exits 5 when the world cannot be built, naming the reason" do
      _stdout, stderr, status = run_cli("plan", *app_target("full_app", "order_archiver.rb"))

      expect(status.exitstatus).to eq(5)
      expect(stderr).to include("reason: unknown_column_type")
      expect(stderr).to include("orders.service_area")
    end

    it "says so when it is not pointed at an app root" do
      stdout, stderr, status = run_cli("plan", target("invoice_calculator.rb", "call"))

      expect(stdout).to include("InvoiceCalculator#call")
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("Rails application root")
    end

    it "flags a clock-dependent target in the output, not just in the data" do
      stdout, _stderr, = run_cli("plan", target("clock_service.rb", "ExpiryChecker#call"))

      expect(stdout).to include("Time.now (line 9)")
      expect(stdout).to include("reads the process clock, not Time.zone")
    end

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

  describe "pin" do
    it "exits 2 when it is not pointed at an app, since there is no world to build" do
      _stdout, stderr, status = run_cli("pin", target("invoice_calculator.rb", "call"))

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("Rails application root")
    end

    %w[insta approvals].each do |backend|
      it "refuses the unbuilt #{backend} backend before doing any work" do
        _stdout, stderr, status = run_cli(
          "pin", "--snapshot", backend, target("invoice_calculator.rb", "call")
        )

        expect(status.exitstatus).not_to eq(0)
        expect(stderr).to include("#{backend} snapshot backend is not built yet")
        expect(stderr).to include("only `inline` is")
        expect(stderr).to include("where a reviewer can read it")
      end
    end

    it "rejects a backend name that is not in the spec at all" do
      _stdout, stderr, status = run_cli("pin", "--snapshot", "yaml", target("invoice_calculator.rb", "call"))

      expect(status.exitstatus).not_to eq(0)
      expect(stderr.downcase).to include("yaml")
    end

    it "accepts the default backend without comment" do
      _stdout, stderr, _status = run_cli("pin", "--snapshot", "inline", target("invoice_calculator.rb", "call"))

      expect(stderr).not_to include("snapshot backend")
    end
  end

  describe "report" do
    it "says so when there is no report to print yet" do
      _stdout, stderr, status = run_cli("report", "--app", File.join(ROOT, "spec", "fixtures", "apps", "cyclic_app"))

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("Run `pinspec pin` first")
    end
  end
end
