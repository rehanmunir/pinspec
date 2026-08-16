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

  describe "argument order" do
    def app_dir(app)
      File.join(ROOT, "spec", "fixtures", "apps", app)
    end

    # --app-env used to be a Thor array option, which swallowed the positional
    # target unless it came first. That is a footgun, not a feature.
    it "accepts the target after the flags" do
      root = app_dir("basic_app")
      stdout, _stderr, status = run_cli(
        "plan", "--app", root, "--cases", "1",
        File.join(root, "app/services/invoice_calculator.rb#call")
      )

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("InvoiceCalculator#call")
    end

    # The specific footgun: as an array option, --app-env consumed every following
    # word including the target. Repeatable takes one pair per flag instead.
    it "accepts the target before the flags" do
      root = app_dir("basic_app")
      stdout, _stderr, status = run_cli(
        "plan", File.join(root, "app/services/invoice_calculator.rb#call"), "--app", root
      )

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("InvoiceCalculator#call")
    end

    it "takes a bare file and assumes #call" do
      root = app_dir("basic_app")
      stdout, _stderr, status = run_cli(
        "plan", "--app", root, File.join(root, "app/services/invoice_calculator.rb")
      )

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("InvoiceCalculator#call")
    end

    it "collects a repeated --app-env into a hash without eating the target" do
      cli = Pinspec::CLI.new([], { "app-env" => ["GEM_HOME=/gems", "LANG=C"] })

      expect(cli.send(:app_env)).to eq("GEM_HOME" => "/gems", "LANG" => "C")
    end

    it "handles a value containing an equals sign" do
      cli = Pinspec::CLI.new([], { "app-env" => ["PATH=/a=b:/c"] })

      expect(cli.send(:app_env)).to eq("PATH" => "/a=b:/c")
    end
  end

  # 0.1.0 documented `--app-env A=1 B=2 C=3`, because the option was a Thor array.
  # Making it repeatable fixed the option swallowing the target, but it would also
  # have silently reinterpreted every existing invocation - the extra pairs would
  # arrive as positional arguments.
  describe "the 0.1.0 --app-env form" do
    def cli(app_env: nil)
      Pinspec::CLI.new([], app_env ? { "app-env" => app_env } : {})
    end

    def target_from(instance, *args)
      instance.send(:target_from, args)
    end

    it "still understands trailing KEY=VALUE pairs" do
      instance = cli
      allow(instance).to receive(:warn)

      expect(target_from(instance, "app/services/foo.rb", "A=1", "B=2")).to eq("app/services/foo.rb")
      expect(instance.send(:app_env)).to eq("A" => "1", "B" => "2")
    end

    it "finds the target wherever it sits among them" do
      instance = cli
      allow(instance).to receive(:warn)

      expect(target_from(instance, "A=1", "B=2", "app/services/foo.rb")).to eq("app/services/foo.rb")
    end

    it "combines both forms, with the repeatable one winning a conflict" do
      instance = cli(app_env: ["A=new"])
      allow(instance).to receive(:warn)
      target_from(instance, "foo.rb", "A=old", "B=2")

      expect(instance.send(:app_env)).to eq("A" => "new", "B" => "2")
    end

    it "says the form is old without failing on it" do
      instance = cli
      expect(instance).to receive(:warn).with(/0\.1\.0 form and still works/)

      target_from(instance, "foo.rb", "A=1")
    end

    it "stays quiet for the current form" do
      instance = cli(app_env: ["A=1"])
      expect(instance).not_to receive(:warn)

      target_from(instance, "foo.rb")
    end

    it "refuses when there is no target at all" do
      instance = cli
      allow(instance).to receive(:warn)

      expect { target_from(instance, "A=1", "B=2") }
        .to raise_error(Pinspec::TargetNotFound, /no target given/)
    end

    it "refuses two targets rather than silently pinning one" do
      instance = cli

      expect { target_from(instance, "a.rb", "b.rb") }
        .to raise_error(Pinspec::AmbiguousTarget, /more than one target/)
    end

    # A path is not a KEY=VALUE pair even when it contains an equals sign, because
    # the pair form requires an identifier before it.
    it "does not mistake a path containing an equals sign for a pair" do
      instance = cli

      expect(target_from(instance, "app/services/a=b.rb")).to eq("app/services/a=b.rb")
    end

  end

  describe "pin" do
    it "exits 2 when it is not pointed at an app, since there is no world to build" do
      _stdout, stderr, status = run_cli("pin", target("invoice_calculator.rb", "call"))

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("Rails application root")
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
