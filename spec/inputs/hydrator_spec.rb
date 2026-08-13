# frozen_string_literal: true

# M-06's other half: turning real rows into ImportClusters at plan time.
#
# This is the v0.2 -> v0.3 structural fix. v0.1 handed the probe a row id, so the
# emitted spec pointed at a row that did not exist in the test database and the
# whole "IDs differ" failure class followed. Nothing here opens a connection,
# which is precisely why the hard part is testable.
RSpec.describe Pinspec::Inputs::Hydrator do
  let(:profile) do
    Pinspec::Analyzer::AppProfileReader.read(File.expand_path("../fixtures/apps/full_app", __dir__))
  end
  let(:schema)   { profile.schema }
  let(:redactor) { Pinspec::Inputs::Redactor.new }

  def hydrate(table, rows, all_rows = nil, target_source: "", **options)
    described_class
      .new(schema: schema, redactor: redactor, factories: profile.factories, **options)
      .hydrate(table, rows, all_rows || { table => rows }, target_source: target_source)
  end

  # The model constant an imported row is created with. This had its own camelizing
  # copy of a question DependencyResolver#model_for already answered, and the copies
  # had drifted: on the first real application every imported row failed with
  # `uninitialized constant SpreeOrder`, because the model is `Spree::Order`.
  describe "naming the model for an imported row on an engine-backed app" do
    let(:engine) do
      Pinspec::Analyzer::AppProfileReader.read(File.expand_path("../fixtures/apps/engine_app", __dir__))
    end

    def hydrate_engine(**options)
      described_class.new(schema: engine.schema, redactor: Pinspec::Inputs::Redactor.new(enabled: false),
                          factories: engine.factories, **options)
                     .hydrate("shop_orders", [{ "id" => 7, "total" => "10.0", "shop_user_id" => 3 }],
                              { "shop_orders" => [{ "id" => 7, "total" => "10.0", "shop_user_id" => 3 }] })
    end

    it "uses the factory's declared class" do
      clusters, = hydrate_engine

      expect(clusters.first.model).to eq("Shop::Order")
    end

    # There is no camelizing fallback any more. It produced `SpreeOrder` - a constant
    # that does not exist - and its only effect on the app that reached it was an error
    # naming the application instead of the omission. Forgetting the factories is now
    # an argument error at the call site.
    it "cannot be constructed without the factories it needs to answer" do
      expect { described_class.new(schema: engine.schema, redactor: Pinspec::Inputs::Redactor.new) }
        .to raise_error(ArgumentError, /factories/)
    end

    # Passing nil satisfies the keyword but not the requirement, and the failure would
    # otherwise surface as `uninitialized constant ShopOrder` deep inside the probe -
    # an error that names the application instead of the caller's omission.
    it "rejects nil factories as loudly as omitting them" do
      expect do
        described_class.new(schema: engine.schema, redactor: Pinspec::Inputs::Redactor.new, factories: nil)
      end.to raise_error(ArgumentError, /engine prefix/)
    end
  end

  def attr_of(cluster, name)
    Pinspec::Tags.decode(cluster.attrs[name])
  end

  let(:rows) do
    {
      "contracts" => [{
        "id" => 7, "company_id" => 3, "warehouse_id" => nil, "title" => "Big deal",
        "code" => "AB12", "signed_at" => "2020-01-01T00:00:00Z", "starts_on" => "2020-02-01",
        "created_at" => "2019-05-05T00:00:00Z", "updated_at" => "2019-06-06T00:00:00Z"
      }],
      "companies" => [{ "id" => 3, "name" => "Acme Corporation" }]
    }
  end

  describe "shaping a row into something both hosts can rebuild" do
    subject(:clusters) { hydrate("contracts", rows["contracts"], rows).first }

    it "emits a required parent before the row that needs it" do
      expect(clusters.map(&:table)).to eq(%w[companies contracts])
    end

    it "drops the primary key, because an id cannot survive a rollback" do
      expect(clusters.last.attrs).not_to have_key("id")
    end

    it "drops volatile columns, which differ every run" do
      expect(clusters.last.attrs).not_to have_key("created_at")
      expect(clusters.last.attrs).not_to have_key("updated_at")
    end

    it "rewrites an intra-cluster foreign key to a ref" do
      contract = clusters.last

      expect(contract.attrs["company_id"]).to eq("t" => "ref", "v" => "imported_company_1")
    end

    # ContextBuilder mints `company_1` for records it creates, and these names are
    # embedded in the attrs above. A collision would silently point a foreign key
    # at the wrong record.
    it "namespaces its refs away from the ones the plan creates" do
      expect(clusters.map(&:name)).to all(start_with("imported_"))
    end

    it "keeps the row's own data, tagged" do
      contract = clusters.last

      expect(attr_of(contract, "title")).to eq("Big deal")
      expect(attr_of(contract, "code")).to eq("AB12")
      expect(attr_of(contract, "starts_on")).to eq("2020-02-01")
    end

    it "hashes the provenance, so a committed spec does not map to production ids" do
      expect(clusters.last.source).to match(%r{\Asample:contracts:[0-9a-f]{8}\z})
      expect(clusters.last.source).not_to include("7")
    end

    it "names the model each import will be created through" do
      expect(clusters.map(&:model)).to eq(%w[Company Contract])
    end
  end

  describe "a parent outside the sampled rows" do
    it "leaves a nullable one null and says so" do
      # The contract points at warehouse 99, which was not sampled. warehouse_id is
      # nullable, so the import nulls it rather than carrying a dangling id.
      contract_rows = [rows["contracts"].first.merge("warehouse_id" => 99)]
      all_rows      = rows.merge("contracts" => contract_rows)

      clusters, notes = hydrate("contracts", contract_rows, all_rows)
      contract = clusters.find { |c| c.table == "contracts" }

      expect(contract.attrs["warehouse_id"]).to eq("t" => "nil")
      expect(notes.map { |n| n[:kind] }).to include(:cross_cluster_nulled)
      expect(notes.map { |n| n[:kind] }).not_to include(:row_discarded)
    end

    it "discards a row whose required parent was not sampled, rather than importing it broken" do
      orphan = { "contracts" => rows["contracts"], "companies" => [] }

      clusters, notes = hydrate("contracts", rows["contracts"], orphan)

      expect(clusters.map(&:table)).to eq(["contracts"])
      expect(clusters.first.attrs).not_to have_key("company_id")
      expect(notes.map { |n| n[:kind] }).to include(:row_discarded)
      expect(notes.find { |n| n[:kind] == :row_discarded }[:detail]).to include("companies")
    end
  end

  describe "caps" do
    it "stops at the row budget rather than importing a whole table" do
      clusters, = hydrate("contracts", rows["contracts"], rows, max_rows: 1)

      expect(clusters.size).to eq(1)
    end

    it "stops descending at the depth cap" do
      clusters, = hydrate("contracts", rows["contracts"], rows, max_depth: 0)

      # The parent is past the cap, so only the root row is emitted and its
      # foreign key has no ref to point at.
      expect(clusters.map(&:table)).to eq(["contracts"])
    end
  end

  describe "redaction" do
    let(:people_rows) do
      { "people" => [{ "id" => 1, "full_name" => "Rehan Munir" }] }
    end

    it "rewrites a personal column and records which" do
      clusters, = hydrate("people", people_rows["people"], people_rows)

      expect(attr_of(clusters.first, "full_name")).not_to eq("Rehan Munir")
      expect(clusters.first.redacted).to eq(["full_name"])
    end

    it "preserves length, so a target that truncates or validates sees the same shape" do
      clusters, = hydrate("people", people_rows["people"], people_rows)

      expect(attr_of(clusters.first, "full_name").length).to eq("Rehan Munir".length)
    end

    it "flags and notes it when the target reads a rewritten attribute" do
      source = "def call\n  @person.full_name.upcase\nend\n"

      clusters, notes = hydrate("people", people_rows["people"], people_rows, target_source: source)

      expect(clusters.first).to be_redaction_read
      expect(notes.map { |n| n[:kind] }).to include(:redaction_read)
      expect(notes.find { |n| n[:kind] == :redaction_read }[:detail]).to include("line 2")
    end

    it "does not flag a target that never reads it" do
      clusters, = hydrate("people", people_rows["people"], people_rows, target_source: "def call\n  1\nend\n")

      expect(clusters.first).not_to be_redaction_read
    end

    it "can be turned off, leaving the row verbatim" do
      plain = described_class.new(schema: schema, factories: profile.factories,
                                  redactor: Pinspec::Inputs::Redactor.new(enabled: false))
      clusters, = plain.hydrate("people", people_rows["people"], people_rows)

      expect(attr_of(clusters.first, "full_name")).to eq("Rehan Munir")
      expect(clusters.first.redacted).to be_empty
    end
  end
end

RSpec.describe Pinspec::Inputs::Redactor do
  subject(:redactor) { described_class.new }

  def rewrite(column, value, ordinal: 1)
    redactor.redact({ column => value }, ordinal: ordinal).first[column]
  end

  describe "what it rewrites" do
    it "covers the built-in personal attributes" do
      expect(redactor.redacts?("email")).to be(true)
      expect(redactor.redacts?("ssn")).to be(true)
      expect(redactor.redacts?("api_key")).to be(true)
    end

    # `name` is far too common as a non-personal column - a product name, a status
    # name - and redacting it would rewrite half of every schema.
    it "leaves a bare `name` alone" do
      expect(redactor.redacts?("name")).to be(false)
    end

    it "accepts extra attributes from configuration" do
      expect(described_class.new(attributes: %w[nickname]).redacts?("nickname")).to be(true)
    end
  end

  describe "domain and length preservation, which is the whole point" do
    # v0.2 rewrote to user1@example.test, changing both the domain and the length,
    # so a target routing on the domain or validating on length observes different
    # behaviour and the snapshot freezes something that never happens.
    it "keeps an email's domain" do
      expect(rewrite("email", "rehan.munir@acme.co")).to end_with("@acme.co")
      expect(rewrite("email", "rehan.munir@acme.co")).not_to include("rehan")
    end

    it "keeps an email's length" do
      original = "rehan.munir@acme.co"

      expect(rewrite("email", original).length).to eq(original.length)
    end

    it "keeps a phone number's shape, so anything parsing it still parses it" do
      rewritten = rewrite("phone", "+1 (555) 867-5309")

      expect(rewritten).to match(/\A\+\d \(\d{3}\) \d{3}-\d{4}\z/)
      expect(rewritten).not_to include("867")
    end

    it "keeps an SSN's separators" do
      expect(rewrite("ssn", "123-45-6789")).to match(/\A\d{3}-\d{2}-\d{4}\z/)
    end

    it "keeps a token's length" do
      token = "a" * 40

      expect(rewrite("api_key", token).length).to eq(40)
      expect(rewrite("api_key", token)).not_to eq(token)
    end
  end

  describe "determinism" do
    it "rewrites the same row to the same value, so a plan stays content-addressable" do
      expect(rewrite("email", "a@b.com")).to eq(rewrite("email", "a@b.com"))
    end

    it "rewrites different rows differently" do
      expect(rewrite("email", "person@b.com", ordinal: 1))
        .not_to eq(rewrite("email", "person@b.com", ordinal: 2))
    end
  end

  describe "read detection" do
    it "finds a method call, a symbol, and a string key" do
      expect(redactor.reads_in("x.email\n", ["email"]).first).to include(attribute: "email", line: 1)
      expect(redactor.reads_in("a\nb\nrow[:ssn]\n", ["ssn"]).first[:line]).to eq(3)
      expect(redactor.reads_in("h[\"phone\"]\n", ["phone"]).first[:line]).to eq(1)
    end

    it "does not match a longer name that merely contains the attribute" do
      expect(redactor.reads_in("x.email_address_confirmed\n", ["email"])).to be_empty
    end

    it "reports nothing when redaction is off" do
      expect(described_class.new(enabled: false).reads_in("x.email", ["email"])).to be_empty
    end
  end
end

RSpec.describe Pinspec::Inputs::Sampler do
  describe ".choose_env" do
    # v0.2 defaulted to the test database, which is empty - silently reducing
    # pinspec to boundary values while the whole hydration design went unused.
    it "prefers development when it has rows" do
      expect(described_class.choose_env(available: %w[development test],
                                        counts: { "development" => 400, "test" => 0 }))
        .to eq("development")
    end

    it "falls back to test when development is empty" do
      expect(described_class.choose_env(available: %w[development test],
                                        counts: { "development" => 0, "test" => 12 }))
        .to eq("test")
    end

    it "prefers development when both have rows, which is the reversal of v0.2" do
      expect(described_class.choose_env(available: %w[development test],
                                        counts: { "development" => 400, "test" => 30 }))
        .to eq("development")
    end

    it "honours an explicit override" do
      expect(described_class.choose_env(available: %w[development], override: "staging"))
        .to eq("staging")
    end

    it "still picks something when nothing has rows" do
      expect(described_class.choose_env(available: %w[test], counts: {})).to eq("test")
    end
  end

  describe "production guard" do
    it "recognises a production-looking name" do
      expect(described_class).to be_production_like("myapp_production")
      expect(described_class).to be_production_like("live-db")
      expect(described_class).not_to be_production_like("myapp_development")
    end

    it "refuses without confirmation, at exit 11" do
      expect { described_class.guard_production!("myapp_production") }
        .to raise_error(Pinspec::EnvironmentRefused) { |error|
          expect(error.exit_code).to eq(11)
          expect(error.message).to include("only ever")
        }
    end

    it "proceeds when confirmed" do
      expect { described_class.guard_production!("myapp_production", confirmed: true) }.not_to raise_error
    end

    it "says nothing about an ordinary database" do
      expect { described_class.guard_production!("myapp_development") }.not_to raise_error
    end
  end

  describe "the generated script" do
    subject(:script) { described_class.script_for([{ table: "invoices", status_column: "status", limit: 5 }]) }

    it "only ever SELECTs" do
      expect(script).not_to match(/\b(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)\b/)
      expect(script).to include("SELECT")
    end

    it "refuses to run outside a Rails application" do
      expect(script).to include("ActiveRecord is not loaded")
    end

    it "requires only the standard library" do
      requires = script.scan(/^\s*require ["']([^"']+)["']/).flatten

      expect(requires).to eq(["json"])
    end

    it "samples at deterministic positions rather than randomly" do
      expect(script).not_to match(/\brand\b|RANDOM\(\)|\bshuffle\b/)
      expect(script).to include("pinspec_offsets")
    end

    it "carries the table request it was built for" do
      expect(script).to include('"table": "invoices"')
      expect(script).to include('"status_column": "status"')
    end

    # The script runs in the app's Ruby, not pinspec's, and CI syntax-checks the
    # committed snapshot on 2.6. This guards against the snapshot going stale.
    #
    # The version stamp is normalised out. What this guard is for is a change to the
    # generated SYNTAX that nobody re-checked on 2.6; a release bump changes the stamp
    # and nothing else, and a guard that cried stale on every release would train
    # whoever saw it to regenerate without looking.
    it "matches the committed snapshot that CI checks on Ruby 2.6" do
      snapshot = File.expand_path("../fixtures/probe/sampler_snapshot.rb", __dir__)
      expected = described_class.script_for([
                                              { table: "invoices", status_column: "status", limit: 5 },
                                              { table: "customers", status_column: nil, limit: 5 }
                                            ])

      unstamp = ->(source) { source.sub(/Generated by pinspec \S+\./, "Generated by pinspec.") }

      expect(unstamp.call(File.read(snapshot))).to eq(unstamp.call(expected)),
                                                   "regenerate spec/fixtures/probe/sampler_snapshot.rb"
    end

    # ...and the stamp itself is still asserted, so "normalised out" does not become
    # "unversioned".
    it "stamps the version that generated it" do
      expect(script).to include("Generated by pinspec #{Pinspec::VERSION}.")
    end
  end
end
