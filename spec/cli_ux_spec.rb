# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"

RSpec.describe "the command surface a new user meets" do
  UX_ROOT = File.expand_path("..", __dir__)

  def run_cli(*args)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(UX_ROOT, "lib"), File.join(UX_ROOT, "exe", "pinspec"), *args
    )
    [stdout.force_encoding("UTF-8"), stderr.force_encoding("UTF-8"), status]
  end

  describe "help" do
    it "leads with pin and puts the diagnostics last" do
      stdout, = run_cli("help")
      order = stdout.scan(/^\s+pinspec (\w+)/).flatten

      expect(order.first).to eq("pin")
      expect(order.index("plan")).to be > order.index("analyze")
      expect(order.index("capture")).to be > order.index("validate")
    end

    it "says which two commands are diagnostics" do
      stdout, = run_cli("help")

      expect(stdout).to match(/plan.*Diagnostic/)
      expect(stdout).to match(/capture.*Diagnostic/)
    end

    it "advertises a directory as a valid target" do
      stdout, = run_cli("help", "pin")

      expect(stdout).to include("directory")
    end
  end

  describe "init" do
    # A real application, copied so init can write into it.
    let(:app) do
      dir = Dir.mktmpdir
      FileUtils.cp_r(Dir[File.join(UX_ROOT, "spec/fixtures/apps/basic_app", "*")], dir)
      dir
    end

    it "writes a config a human would commit" do
      _stdout, _stderr, status = run_cli("init", app)
      body = File.read(File.join(app, ".pinspec.yml"))

      expect(status.exitstatus).to eq(0)
      expect(body).to include("cases:")
      expect(body).not_to include(Dir.home)
      expect(body.lines.size).to be < 20
    end

    it "refuses to clobber an existing one" do
      run_cli("init", app)
      _stdout, stderr, status = run_cli("init", app)

      expect(status.exitstatus).to eq(13)
      expect(stderr).to include("already exists")
    end

    it "overwrites with --force" do
      run_cli("init", app)
      _stdout, _stderr, status = run_cli("init", app, "--force")

      expect(status.exitstatus).to eq(0)
    end
  end

  # The commercial point: everyone now has an agent that writes tests, and nobody
  # verifies them. The Verifier never knew where a spec came from, so this needed a
  # command and nothing else.
  describe "verify, on a spec pinspec did not write" do
    let(:app) { File.join(UX_ROOT, "spec/fixtures/apps/rails71_basic") }

    around do |example|
      @written = []
      example.run
      @written.each { |f| FileUtils.rm_f(f) }
    end

    def write_spec(name, body)
      path = File.join(app, "spec", name)
      File.write(path, body)
      @written << path
      File.join("spec", name)
    end

    it "passes a clean hand-written spec" do
      rel = write_spec("ux_ok_spec.rb", <<~RUBY)
        require "spec_helper"
        RSpec.describe("arithmetic") { it("adds") { expect(2 + 2).to eq(4) } }
      RUBY

      stdout, _stderr, status = run_cli("verify", rel, "--app", app)

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("isolated")
      expect(stdout).to include("green")
    end

    # A spec that passes where it was written and fails on any CI in another
    # timezone. This is the failure an agent produces without noticing.
    it "catches a timezone dependency a human or an agent would miss" do
      rel = write_spec("ux_tz_spec.rb", <<~RUBY)
        require "spec_helper"
        RSpec.describe("dates") do
          it("formats") { expect(Time.now.strftime("%z")).to eq("+0000") }
        end
      RUBY

      _stdout, stderr, status = run_cli("verify", rel, "--app", app)

      expect(status.exitstatus).to eq(9)
      expect(stderr).to include("hostile")
    end

    it "says so when the file is not there" do
      _stdout, stderr, status = run_cli("verify", "spec/nope_spec.rb", "--app", app)

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("no spec file at")
    end
  end

  describe "a config it cannot honour" do
    let(:app) do
      dir = Dir.mktmpdir
      FileUtils.cp_r(Dir[File.join(UX_ROOT, "spec/fixtures/apps/basic_app", "*")], dir)
      dir
    end

    # A typo in a config file is otherwise silent, and the user concludes the
    # setting does not work.
    it "names the unknown key when planning" do
      File.write(File.join(app, ".pinspec.yml"), "case: 5\n")
      _stdout, stderr, status = run_cli(
        "plan", "--app", app, File.join(app, "app/services/invoice_calculator.rb")
      )

      expect(status.exitstatus).to eq(13)
      expect(stderr).to include('unknown key "case"')
    end

    it "names it on analyze too, which is the command people run first" do
      File.write(File.join(app, ".pinspec.yml"), "case: 5\n")
      _stdout, stderr, status = run_cli("analyze", app)

      expect(status.exitstatus).to eq(13)
      expect(stderr).to include("Known keys")
    end
  end
end
