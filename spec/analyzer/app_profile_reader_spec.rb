# frozen_string_literal: true

# M-04 acceptance, spec v0.3 §7. This is the module that makes `analyze` a
# pre-engagement hazard report, so the examples are about hazards being *named*,
# not merely detected: an unread Gemfile.lock, an untransacted suite, a second
# writing database, and a Rails version below the floor all have to be loud.
RSpec.describe Pinspec::Analyzer::AppProfileReader do
  def profile(app, **options)
    described_class.read(File.expand_path("../fixtures/apps/#{app}", __dir__), **options)
  end

  describe "a plain modern app" do
    subject(:app) { profile("basic_app") }

    it "reads the Rails and Ruby versions from Gemfile.lock" do
      expect(app.rails_version).to eq("7.1.3.2")
      expect(app.ruby_version).to eq("3.2.2")
      expect(app.rails_floor_ok).to be(true)
      expect(app).to be_rails_floor_ok
    end

    it "finds nothing that is not there" do
      expect(app.auth).to eq(:none)
      expect(app.authz).to eq(:none)
      expect(app.tenancy).to eq(:none)
      expect(app.soft_delete).to eq(:none)
      expect(app.versioning).to eq(:none)
      expect(app.flags).to eq(:none)
      expect(app.attachments).to be_empty
      expect(app.spring).to be(false)
      expect(app.model_findings).to be_empty
    end

    it "defaults the locale and zone when nothing overrides them" do
      expect(app.default_locale).to eq(:en)
      expect(app.default_zone).to eq("UTC")
    end

    it "reads the test stack" do
      expect(app.test_stack.framework).to eq(:rspec)
      expect(app.test_stack.webmock).to be(true)
      expect(app.test_stack.vcr).to be(false)
      expect(app.test_stack.database_cleaner_gem).to be(false)
      expect(app.test_stack.snapshot_backends).to be_empty
      expect(app.test_stack).to be_stubs_http
    end

    it "aggregates the schema and factory readers, so analyze is one call" do
      expect(app.schema).to be_a(Pinspec::SchemaGraph)
      expect(app.factories).to be_a(Pinspec::FactoryIndex)
      expect(app.schema.table_names).to include("invoices")
      expect(app.factories.factory(:invoice)).not_to be_nil
    end

    it "has nothing to warn about" do
      expect(app.warnings).to be_empty
      expect(app.notes).to be_empty
    end

    describe "Gemfile.lock parsing" do
      it "reads resolved specs and not dependency or DEPENDENCIES lines" do
        # factory_bot_rails is a resolved spec at four spaces; `rails (~> 7.1)`
        # under DEPENDENCIES sits at two, and `actionview (= 7.1.3.2)` at six.
        expect(app.rails_version).not_to include("~>")
      end

      it "keeps a prerelease version intact rather than truncating it" do
        # Keeping only digits and dots turns "7.2.0.beta1" into "7.2.0.", which
        # Gem::Version rejects - a crash in the middle of a report.
        odd = profile("oddities_app")

        expect(odd.rails_version).to eq("7.2.0.beta1")
        expect(odd.rails_floor_ok).to be(true)
      end

      it "does not crash on a version it cannot read" do
        corrupt = profile("corrupt_lock_app")

        expect(corrupt.rails_version).to eq("edge")
        expect(corrupt.rails_floor_ok).to be_nil
        expect(corrupt.notes.map { |n| n[:kind] }).to include(:unparseable_rails_version)
      end
    end
  end

  describe "an app that made the less common choices" do
    subject(:app) { profile("oddities_app") }

    it "prefers apartment over acts_as_tenant, and refuses it in the warnings" do
      expect(app.tenancy).to eq(:apartment)
      expect(app.warnings.join).to include("ros-apartment tenancy is not supported")
    end

    it "detects discard from an include, not just from the gem" do
      expect(app.soft_delete).to eq(:discard)
      expect(app.findings(:discard).map(&:model)).to eq(["Warehouse"])
    end

    it "falls back to CurrentAttributes for auth when there is no devise" do
      expect(app.auth).to eq(:current_attributes)
    end

    it "detects a minitest suite and any snapshot backends" do
      expect(app.test_stack.framework).to eq(:minitest)
      expect(app.test_stack.snapshot_backends).to eq(%i[insta approvals])
      expect(app.attachments).to eq([:paperclip])
    end

    it "qualifies a namespaced model" do
      # module Billing; class Statement < ApplicationRecord
      expect(app.after_commit_models.map(&:model)).to eq(["Billing::Statement"])
    end

    it "trusts connects_to even with no database.yml to corroborate it" do
      expect(File).not_to exist(File.expand_path("../fixtures/apps/oddities_app/config/database.yml", __dir__))
      expect(app.multi_db).to be(true)
    end

    it "is untransacted when the Rails wrapper is off and nothing replaces it" do
      expect(app.db_cleaner).to eq(:none)
      expect(app.transactional_fixtures).to be(false)
      expect(app.isolation).to eq(:truncation)
    end
  end

  describe "an app carrying every hazard" do
    subject(:app) { profile("full_app") }

    it "detects auth, authz, tenancy, soft delete, versioning and flags from the lock" do
      expect(app.auth).to eq(:devise)
      expect(app.authz).to eq(:cancancan)
      expect(app.tenancy).to eq(:acts_as_tenant)
      expect(app.soft_delete).to eq(:paranoia)
      expect(app.versioning).to eq(:paper_trail)
      expect(app.flags).to eq(:flipper)
      expect(app.spring).to be(true)
    end

    it "detects attachments from usage as well as from gems" do
      # ActiveStorage ships inside Rails, so has_one_attached is its evidence.
      expect(app.attachments).to contain_exactly(:active_storage, :carrierwave)
    end

    it "reads the locale from application.rb" do
      expect(app.default_locale).to eq(:de)
    end

    it "recognises a gem that only appears in its hyphenated variants" do
      # This lock has database_cleaner-active_record and database_cleaner-core,
      # and no plain database_cleaner entry at all.
      expect(app.test_stack.database_cleaner_gem).to be(true)
    end

    it "lets config/environments/test.rb win, because the probe runs under test" do
      # application.rb says "Berlin"; test.rb says "UTC".
      expect(app.default_zone).to eq("UTC")
    end

    it "records every model macro with its file and line" do
      kinds = app.model_findings.group_by(&:kind)

      expect(kinds[:acts_as_tenant].map(&:model)).to eq(["Order"])
      expect(kinds[:paper_trail].map(&:model)).to eq(["Order"])
      expect(kinds[:paranoia].map(&:model)).to eq(["Order"])
      expect(kinds[:active_storage].map(&:model)).to eq(["Order"])
      expect(kinds[:default_scope].map(&:model)).to eq(["Order"])
      expect(kinds[:connects_to].map(&:model)).to eq(["Animal"])
      expect(kinds[:current_attributes].map(&:model)).to eq(["Current"])
      expect(kinds[:default_scope].first.line).to be > 0
    end

    it "treats every after_commit variant as the same hazard" do
      # after_commit and after_update_commit both fire outside the transaction.
      expect(app.after_commit_models.map(&:model)).to eq(%w[Order Order])
      expect(app.findings(:after_commit).size).to eq(2)
    end

    it "quotes the multi-database rollback warning verbatim" do
      expect(app.multi_db).to be(true)
      expect(app.warnings).to include(Pinspec::MULTI_DB_ROLLBACK_WARNING)
    end

    it "warns about every hazard it found" do
      joined = app.warnings.join("\n")

      expect(joined).to include("after_commit callbacks DO fire")
      expect(joined).to include("queue adapter to :inline")
      expect(joined).to include("default_scope")
      expect(joined).to include("Attachments present")
      expect(joined).to include("DISABLE_SPRING=1")
    end
  end

  describe "isolation, the regime both hosts must share" do
    it "is :transaction when nothing turns the Rails wrapper off" do
      app = profile("basic_app")

      expect(app.isolation).to eq(:transaction)
      expect(app.isolation_source).to include("use_transactional_fixtures = true")
    end

    it "is :truncation when DatabaseCleaner truncates" do
      app = profile("full_app")

      expect(app.db_cleaner).to eq(:truncation)
      expect(app.transactional_fixtures).to be(false)
      expect(app.isolation).to eq(:truncation)
    end

    # The canonical DatabaseCleaner setup. Reading use_transactional_fixtures
    # alone would call this suite untransacted, decide after_commit fires, and
    # diverge the probe from the emitted spec.
    it "lets DatabaseCleaner's :transaction outrank use_transactional_fixtures = false" do
      app = profile("legacy_app")

      expect(app.transactional_fixtures).to be(false)
      expect(app.db_cleaner).to eq(:transaction)
      expect(app.isolation).to eq(:transaction)
      expect(app.isolation_source).to include("DatabaseCleaner.strategy = :transaction")
    end

    it "assumes the first strategy is the default, and says so" do
      # :transaction by default with :truncation for js: true specs is everywhere.
      app = profile("legacy_app")

      expect(app.notes.map { |n| n[:kind] }).to include(:multiple_db_cleaner_strategies)
      expect(app.notes.find { |n| n[:kind] == :multiple_db_cleaner_strategies }[:detail])
        .to include("transaction, truncation")
    end

    it "warns under :truncation but not under :transaction" do
      expect(profile("full_app").warnings.join).to include("does not wrap examples in a transaction")
      expect(profile("legacy_app").warnings.join).not_to include("does not wrap examples in a transaction")
    end
  end

  describe "multi-database detection" do
    it "trusts connects_to in a model" do
      expect(profile("full_app").multi_db).to be(true)
    end

    it "falls back to two writing configs in database.yml" do
      app = profile("yaml_multidb_app")

      expect(app.findings(:connects_to)).to be_empty
      expect(app.multi_db).to be(true)
    end

    it "does not count a replica as a second writer, and survives ERB" do
      expect(profile("basic_app").multi_db).to be(false)
    end

    it "says so when database.yml cannot be parsed, rather than guessing" do
      app = profile("broken_app")

      expect(app.multi_db).to be(false)
      expect(app.notes.map { |n| n[:kind] }).to include(:unreadable_database_yml)
    end
  end

  describe "a legacy app" do
    subject(:app) { profile("legacy_app") }

    it "reads a 6.1 lock and an old Ruby" do
      expect(app.rails_version).to eq("6.1.7.6")
      expect(app.ruby_version).to eq("2.6.10")
      expect(app.rails_floor_ok).to be(true)
    end

    it "carries the legacy factory DSL through to the profile" do
      expect(app.factories.legacy_dsl).to be(true)
      expect(app.factories.dsl_module).to eq("FactoryGirl")
    end

    it "detects pundit and the database_cleaner gem" do
      expect(app.authz).to eq(:pundit)
      expect(app.test_stack.database_cleaner_gem).to be(true)
    end
  end

  describe "below the Rails floor" do
    it "refuses at analyze time, at exit 10, naming what is missing" do
      expect { profile("old_app") }
        .to raise_error(Pinspec::UnsupportedRailsVersion) { |error|
          expect(error.exit_code).to eq(10)
          expect(error.message).to include("Rails 5.2.8.1")
          expect(error.message).to include("6.0 or newer")
          expect(error.message).to include("insert_all")
          expect(error.message).to include("connects_to")
          expect(error.message).to include("reset_all")
        }
    end

    it "can still be inspected when the floor is not enforced" do
      app = profile("old_app", enforce_floor: false)

      expect(app.rails_version).to eq("5.2.8.1")
      expect(app.rails_floor_ok).to be(false)
      expect(app).not_to be_rails_floor_ok
    end
  end

  describe "an app with no Gemfile.lock" do
    subject(:app) { profile("broken_app") }

    it "degrades instead of refusing, because a first look is still useful" do
      expect(app.rails_version).to be_nil
      expect(app.rails_floor_ok).to be_nil
      expect(app.auth).to eq(:none)
    end

    # "not found" and "not used" are different answers, and reporting the first
    # as the second is how a hazard report becomes misleading.
    it "says that every gem answer is unverified" do
      expect(app.notes.map { |n| n[:kind] }).to include(:no_gemfile_lock)
      expect(app.warnings.join).to include("No Gemfile.lock was read")
    end
  end

  describe "propagated refusals" do
    it "still raises exit 6 for a structure.sql app" do
      expect { profile("sql_app") }
        .to raise_error(Pinspec::SchemaFormatUnsupported) { |error|
          expect(error.exit_code).to eq(6)
        }
    end
  end
end
