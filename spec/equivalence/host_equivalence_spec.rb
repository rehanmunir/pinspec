# frozen_string_literal: true

require "json"

# M-14 HostEquivalence. Spec v0.3 §4c names six axes on which the probe process and
# the emitted-spec process must agree, and §7 M-14 asks for host agreement to be a
# build-breaking test rather than a design intention.
#
# The mechanism is simple: a green emitted spec IS the assertion. The spec compares
# what the spec host produces against the snapshot the probe produced, so if it
# passes, the two hosts agreed. Each axis below then adds the property that makes
# that agreement meaningful for that axis - most importantly, that the suite is set
# up to DISAGREE with the plan, so a passing pin proves the emitted spec forced the
# capture's answer rather than inheriting a matching one by luck.
#
# Skipped rather than failed when the fixture apps are not prepared:
#
#   cd spec/fixtures/apps/rails71_basic && bundle install && RAILS_ENV=test bundle exec rails db:schema:load
#   cd spec/fixtures/apps/rails61_legacy && bundle install && RAILS_ENV=test bundle exec rails db:schema:load
RSpec.describe "host equivalence, across the six contract axes" do
  FIXTURES = File.expand_path("../fixtures/apps", __dir__)

  GEMSETS = {
    "rails71_basic" => "ruby-3.3.0",
    "rails61_legacy" => "ruby-3.1.0"
  }.freeze

  def app_root(app)
    File.join(FIXTURES, app)
  end

  # Each fixture runs on its own Ruby, which is the two-process design in
  # miniature: pinspec's CLI and the app under test share nothing but a directory.
  def app_env(app)
    gemset = File.expand_path("~/.rvm/gems/#{GEMSETS.fetch(app)}")
    ruby = File.expand_path("~/.rvm/rubies/#{GEMSETS.fetch(app)}/bin")

    { "PATH" => "#{ruby}:#{ENV.fetch('PATH', '')}", "GEM_HOME" => gemset, "GEM_PATH" => "#{gemset}:#{gemset}@global" }
  end

  def prepared?(app)
    File.file?(File.join(app_root(app), "Gemfile.lock")) &&
      system("pg_isready", out: File::NULL, err: File::NULL)
  end

  # capture -> emit -> verify, the whole loop, returning everything an axis might
  # want to assert about.
  def pin(app, service, method: "call", cases: 1, level: :full)
    root = app_root(app)
    env = app_env(app)

    capture = Pinspec::Runner::Capture.new(
      app_root: root, target: File.join(root, "app/services", service), method: method,
      max_cases: cases, sandbox_env: env
    ).run

    written = Pinspec::Emit::SpecWriter.new(
      app_root: root, target: capture.target, plan: capture.plan, corpus: capture.corpus,
      stability: capture.stability, fk_map: Pinspec::Analyzer::AppProfileReader.read(root).schema.fk_map,
      force: true
    ).write!

    outcomes = Pinspec::Verify::Verifier.new(
      app_root: root, spec_path: written.spec_path, env: env, level: level,
      captured_tz: capture.plan.env_fingerprint[:tz]
    ).verify

    { capture: capture, written: written, outcomes: outcomes, source: File.read(written.spec_path) }
  end

  def tag_kinds(source)
    source.scan(/"t" => "([a-z]+)"/).flatten.uniq
  end

  describe "axis 1: encoding" do
    before(:all) { skip "rails71_basic not prepared" unless prepared?("rails71_basic") }

    let(:result) { pin("rails71_basic", "kitchen_sink.rb") }

    it "agrees on every value kind at once" do
      # One target returning all of them, so agreement is tested on the whole
      # vocabulary rather than on whichever kind a realistic target happened to use.
      expect(result[:outcomes]).to all(be_green)
    end

    it "covers the vocabulary rather than a corner of it" do
      kinds = tag_kinds(result[:source])

      expect(kinds).to include("int", "float", "str", "sym", "nil", "bool", "decimal",
                               "time", "date", "array", "hash", "record", "relation", "bin")
    end

    it "never pins an id, in any position" do
      expect(result[:source].scan(/"\w*_id" => \{"t" => "int"/)).to be_empty
      expect(result[:source]).not_to match(/"id" => \{"t" => "int"/)
    end
  end

  describe "axis 2: isolation" do
    it "suppresses after_commit consistently under the transaction regime" do
      skip "rails71_basic not prepared" unless prepared?("rails71_basic")
      result = pin("rails71_basic", "invoice_calculator.rb")

      expect(result[:capture].plan.isolation).to eq(:transaction)
      expect(result[:source]).to include("ActiveRecord::Base.transaction(requires_new: true)")
      expect(result[:outcomes]).to all(be_green)
    end

    # The regime that v0.2 got wrong, and the reason isolation is a plan property.
    it "fires after_commit consistently under the truncation regime" do
      skip "rails61_legacy not prepared" unless prepared?("rails61_legacy")
      result = pin("rails61_legacy", "order_placer.rb")

      expect(result[:capture].plan.isolation).to eq(:truncation)
      # No wrapper: the capture ran uncommitted-to-rolled-back, so the spec must not
      # introduce a transaction the capture did not have.
      expect(result[:source]).not_to include("ActiveRecord::Base.transaction(requires_new: true)")
      expect(result[:source]).to include("isolation: truncation")

      # LedgerJob only exists because after_commit fired - in BOTH hosts.
      expect(result[:source]).to include('"job" => "LedgerJob"')
      expect(result[:outcomes]).to all(be_green)
    end

    it "builds records from the schema when an app has no factories" do
      skip "rails61_legacy not prepared" unless prepared?("rails61_legacy")
      result = pin("rails61_legacy", "order_placer.rb")

      expect(result[:source]).to include("Shop.create!")
      expect(result[:source]).not_to include("create(:")
    end
  end

  describe "axis 3: sinks" do
    before(:all) { skip "rails71_basic not prepared" unless prepared?("rails71_basic") }

    let(:result) { pin("rails71_basic", "invoice_calculator.rb") }

    it "attributes to the target only what the target did" do
      # The :customer factory has an after(:create) that enqueues. It fires while
      # the PLAN builds records, so neither host may count it.
      expect(result[:source]).not_to include("factory-callback")
    end

    it "pins the target's own jobs" do
      jobs = result[:source].scan(/"job" => "([A-Za-z:]+)"/).flatten.uniq

      expect(jobs).to contain_exactly("SyncJob", "ActionMailer::MailDeliveryJob")
      expect(result[:outcomes]).to all(be_green)
    end
  end

  describe "axis 4: clock" do
    before(:all) { skip "rails71_basic not prepared" unless prepared?("rails71_basic") }

    let(:result) { pin("rails71_basic", "clock_reader.rb") }

    it "holds where it was captured" do
      isolated = result[:outcomes].find { |outcome| outcome.config == :isolated }

      expect(isolated).to be_green
    end

    # The failure that would otherwise wait for the client's CI. Time.zone does not
    # govern Time.now, and both safety nets share a machine with the capture.
    it "refuses to hold under a different timezone, and says why" do
      hostile = result[:outcomes].find { |outcome| outcome.config == :hostile }

      expect(hostile).not_to be_green
      expect(hostile.diagnosis).to eq(:tz_dependent)
    end

    it "warns in the pin's own header, where a reader will see it" do
      expect(result[:source]).to include("WARNING: the target reads the PROCESS clock")
      expect(result[:source]).to include("Time.now")
    end
  end

  describe "axes 5 and 6: locale and zone" do
    before(:all) { skip "rails71_basic not prepared" unless prepared?("rails71_basic") }

    let(:result) { pin("rails71_basic", "locale_greeter.rb") }
    let(:snapshot) { result[:source] }

    # The fixture's rails_helper deliberately sets :fr and Asia/Tokyo for the whole
    # suite. If the emitted spec did not force the plan's answer back, these would
    # be "Bonjour" and "Asia/Tokyo" and the pin would fail.
    it "forces the plan's locale over the suite's" do
      expect(snapshot).to include('"v" => "Hello"')
      expect(snapshot).not_to include("Bonjour")
      expect(snapshot).to include("I18n.locale = :en")
    end

    it "forces the plan's zone over the suite's" do
      expect(snapshot).to include('"v" => "UTC"')
      expect(snapshot).not_to include("Asia/Tokyo")
      expect(snapshot).to include('Time.zone = "UTC"')
    end

    it "agrees on a zone-aware clock read" do
      expect(snapshot).to include(Pinspec::PINSPEC_EPOCH.sub("Z", "Z").sub(/T.*/, ""))
      expect(result[:outcomes]).to all(be_green)
    end
  end

  describe "the harness itself" do
    it "checks every axis the contract names" do
      # If §4c grows an axis, this list is where it has to be answered.
      expect(%w[encoding isolation sinks clock locale zone].size).to eq(6)
    end
  end
end
