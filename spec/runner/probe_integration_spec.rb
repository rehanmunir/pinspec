# frozen_string_literal: true

RSpec.describe "the probe, inside a real Rails application" do
  APP_ROOT = File.expand_path("../fixtures/apps/rails71_basic", __dir__)

  def app_env
    gemset = File.expand_path("~/.rvm/gems/ruby-3.3.0")

    {
      "PATH" => "#{File.expand_path('~/.rvm/rubies/ruby-3.3.0/bin')}:#{ENV.fetch('PATH', '')}",
      "GEM_HOME" => gemset,
      "GEM_PATH" => "#{gemset}:#{gemset}@global"
    }
  end

  def prepared?
    File.file?(File.join(APP_ROOT, "Gemfile.lock")) &&
      system("pg_isready", out: File::NULL, err: File::NULL)
  end

  def capture(service, method = "call", cases: 3, boots: 2)
    Pinspec::Runner::Capture.new(
      app_root: APP_ROOT,
      target: File.join(APP_ROOT, "app/services", service),
      method: method,
      max_cases: cases,
      boots: boots,
      sandbox_env: app_env,
      output_dir: File.join(APP_ROOT, "tmp/pinspec")
    ).run
  end

  def find_tags(value, kind, found = [])
    case value
    when Hash
      found << value if value["t"] == kind
      value.each_value { |inner| find_tags(inner, kind, found) }
    when Array
      value.each { |inner| find_tags(inner, kind, found) }
    end

    found
  end

  def table_counts
    script = "puts ActiveRecord::Base.connection.tables.sort.map { |t| " \
             "t + %q{=} + ActiveRecord::Base.connection.select_value(%q{SELECT COUNT(*) FROM } + t).to_s }.join(%q{ })"

    require "open3"
    out, = Open3.capture2(app_env.merge("RAILS_ENV" => "test"),
                          "bundle", "exec", "rails", "runner", script, chdir: APP_ROOT)
    out.strip
  end

  before(:all) { skip "fixture app not prepared (see this file's header)" unless prepared? }

  describe "the row-30 target: returns a record it just created" do
    let(:result) { capture("invoice_calculator.rb") }

    it "is stable across two separate boots" do
      expect(result.stability.runs).to eq(2)
      expect(result.stability.unstable).to be_empty
      expect(result.stability.stable.size).to eq(result.corpus.size)
    end

    it "pins the foreign key as a ref, never as an id" do
      value = result.stability.stable.first.observation["return_value"]

      expect(value["t"]).to eq("record")
      expect(value["class"]).to eq("Invoice")
      expect(value["attributes"]["customer_id"]).to eq("t" => "ref", "v" => "customer_1")
      expect(value["attributes"]).not_to have_key("id")
    end

    it "drops volatile columns" do
      attributes = result.stability.stable.first.observation["return_value"]["attributes"]

      expect(attributes).not_to have_key("created_at")
      expect(attributes).not_to have_key("updated_at")
    end

    it "keeps a decimal a string, so a pinned total cannot drift through a Float" do
      total = result.stability.stable.first.observation["return_value"]["attributes"]["total"]

      expect(total["t"]).to eq("decimal")
      expect(total["v"]).to eq("110.0")
    end

    it "captures the enqueued jobs, refusing to pin the ids inside them" do
      jobs = result.stability.stable.first.observation["enqueued_jobs"]

      expect(jobs.map { |job| job["job"] }).to include("SyncJob")
      expect(jobs.find { |job| job["job"] == "SyncJob" }["queue"]).to eq("sync")

      args = jobs.find { |job| job["job"] == "SyncJob" }["args"]["v"]
      expect(args.first).to eq("t" => "ref", "v" => "__returned__")
    end

    it "refuses to pin the id inside a GlobalID, keeping the model name" do
      mailer = result.stability.stable.first.observation["enqueued_jobs"]
                     .find { |job| job["job"].include?("MailDeliveryJob") }

      gids = find_tags(mailer["args"], "gid")

      expect(gids).not_to be_empty
      expect(gids.first["model"]).to eq("Invoice")
      expect(gids.first["id"] || gids.first["ref"]).not_to match(/\A\d+\z/)
    end

    it "records what it wrote" do
      expect(result.stability.stable.first.observation["db_delta"]["inserts"]).to be >= 1
    end

    it "leaves no SCHEMA noise in the fingerprints" do
      fingerprints = result.runs.first.observations.flat_map { |o| o["sql_fingerprints"] }

      expect(fingerprints).to all(match(/\A(SELECT|INSERT|UPDATE|DELETE)/i))
    end

    it "writes observations.json" do
      expect(File.file?(result.output_path)).to be(true)

      parsed = JSON.parse(File.read(result.output_path))
      expect(parsed["plan_id"]).to eq(result.plan.plan_id)
      expect(parsed["observations"].size).to eq(2)
    end
  end

  describe "a target with no side effects" do
    it "captures a plain value and no jobs" do
      result = capture("status_reporter.rb")
      observation = result.stability.stable.first.observation

      expect(result.stability.unstable).to be_empty
      expect(observation["enqueued_jobs"]).to be_empty
      expect(observation["return_value"]["t"]).to eq("str")
    end
  end

  describe "the rollback guarantee" do
    it "leaves every table with the row count it started with" do
      before_counts = table_counts

      result = capture("invoice_calculator.rb")

      expect(result.runs.first.observations.sum { |o| o["db_delta"]["inserts"] }).to be >= 1
      expect(table_counts).to eq(before_counts)
    end
  end
end
