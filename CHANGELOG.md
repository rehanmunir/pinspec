# Changelog

## Unreleased (0.0.1)

M1 is complete: M0 scaffold, all four analyzer modules (M-01 TargetParser, M-02
SchemaReader, M-03 FactoryIndex, M-04 AppProfile), `pinspec analyze` as a
standalone hazard report, and the M-11 mutation-adapter spike. Ready to cut
`0.1.0` (spec v0.3 section 13, M1).

### Investigated

- **M-11 mutation-adapter spike** (`docs/spike-m11-mutation-adapter.md`). Pulled
  forward from M5 because M5's definition of done gated on an unproven backend.
  `mutineer` stays the default: it separates a strong pin from a worthless one
  (80% vs 20% on the same subject), targets a single subject, runs a single spec
  file, emits versioned JSON, and is MIT with zero runtime dependencies - the only
  candidate compatible with adding no gems to a client Gemfile. Its Ruby >= 3.4
  requirement is not a blocker: `--test-command` runs the suite in the app's own
  runtime, verified by scoring a Ruby 2.6.4 suite from Ruby 3.4.6 with an
  identical result. Three contracts corrected as a result - the adapter targets by
  `qualified_name` rather than `source_range`, aspect scoring is one run per
  aspect over a temporary per-aspect spec file, and `--validate` needs Ruby 3.4 in
  the pinspec gemset while the rest of pinspec keeps its 3.2 floor.

### Added

- **M-04 AppProfile** - gem truth from `Gemfile.lock`, test-harness configuration
  from the helper files, per-model hazards from `app/models`, and aggregation of
  M-02 and M-03 so `analyze` is a single call.
  - Detects devise / pundit / cancancan / acts_as_tenant / ros-apartment /
    paranoia / discard / paper_trail / flipper / carrierwave / paperclip /
    spring / webmock / vcr / insta / approvals / database_cleaner, including gems
    that appear only in a hyphenated variant.
  - `isolation`, the regime both hosts must share. DatabaseCleaner's strategy
    outranks `use_transactional_fixtures`, because the canonical DatabaseCleaner
    setup turns the Rails wrapper off precisely so DatabaseCleaner can wrap
    instead - reading the Rails flag alone would call that suite untransacted and
    diverge the probe from the emitted spec.
  - `warnings`: the multi-database rollback-scope text quoted verbatim from spec
    section 12.7, plus untransacted suites, a non-`:test` queue adapter,
    `default_scope` models, attachments, apartment tenancy, and Spring.
  - Locale and time zone from `config/application.rb`, with
    `config/environments/test.rb` winning, because the probe runs under
    `RAILS_ENV=test`.
  - Multi-database detection from `connects_to` in a model, falling back to two
    writing configs in `database.yml` (ERB-tolerant, replicas excluded).
  - Model scan recording `after_commit` and its four variants, `default_scope`,
    `acts_as_tenant`, `has_paper_trail`, attachment macros, `connects_to`,
    `acts_as_paranoid`, `include Discard::Model`, and
    `ActiveSupport::CurrentAttributes` subclasses - each with model, file and
    line, and namespaced models fully qualified.
  - Refuses below the Rails 6.0 floor at `analyze` time with exit 10, naming the
    three APIs it depends on, rather than failing later at the first `insert_all`.
  - Degrades rather than refusing when there is no `Gemfile.lock`, and says so:
    "not found" and "not used" are different answers.
- `Analyzer::Source`, one shared set of Prism helpers. Four copies of the literal
  decoder drifting apart would break the contract that values are recorded as
  source text and never evaluated.

- **M-03 FactoryIndex** - indexes factory_bot / factory_girl definitions from
  `spec/factories/**`, `test/factories/**`, and the single-file conventions.
  Structure only, never executed: a factory body is arbitrary Ruby against the
  app's models, so every value is recorded as source text.
  - `legacy_dsl`, which decides whether emitted specs call `FactoryBot.create`
    or `FactoryGirl.create`, detected from the DSL the files actually use.
  - Attribute kinds: `:block`, `:static` (pre-block factory_girl values),
    `:association` (explicit and implicit), `:sequence`, `:transient`.
  - Traits in declared order, which M-05's validation remedy depends on.
  - Inheritance across both nesting and `parent:`, resolved in a second pass
    because `parent:` can name a factory in a later file. `attributes_for` merges
    a whole ancestor chain and applies traits last; the parent walk terminates on
    mutually parented factories rather than looping.
  - Factory callbacks (`after(:create)` and friends), which fire while the plan
    builds records and are the reason the probe clears its side-effect sinks
    after setup. An attribute named `before` or `after` is not mistaken for one.
  - Hazards: `skip_create`, `initialize_with`, `to_create` - a factory that never
    persists cannot have a plan built on it.
  - An unparsable factory file is skipped with its parse error rather than taking
    the index down, and reported: silence would make M-05 conclude the factory
    does not exist and quietly build a schema-driven record instead.
- `pinspec analyze` now prints the factories section, including which factories
  fire callbacks during setup and which never persist.

- **M-02 SchemaReader** - parses `db/schema.rb` into a `SchemaGraph`. Static
  Prism parse, no database connection and no Rails boot.
  - `fk_map`, the `{"table.column" => "target_table"}` map the probe needs to
    tell a foreign key from a quantity. Without it the identity rewriting that
    makes "returns the record it created" pinnable cannot work at all.
  - Three provenance tiers, with the inferred one flagged: `:foreign_key` (a
    database constraint), `:references` (a declared association), `:heuristic`
    (a `*_id` column whose stem matches a real table). A constraint always wins.
  - Association targets and implicit foreign-key columns are resolved by
    checking the schema's real names, never by pluralizing and hoping.
    `add_foreign_key "line_items", "invoices"` finds `invoice_id`, not
    `invoic_id`; `"addresses"` finds `address_id`, not `addresse_id`.
  - Polymorphic ids get no `fk_map` entry, detected by their `_type` sibling so
    that hand-written pairs in pre-references schemas are caught too. The known
    false negative is documented in the specs: a real foreign key beside an
    unrelated `_type` label column is also dropped, which fails toward visible
    instability rather than toward a wrong rewrite.
  - `create_table` options (`id: false`, `id: :uuid`, `primary_key:`),
    `t.references`/`t.belongs_to` expansion, `t.timestamps`, `t.column` with a
    SQL type string, composite and partial and unique indexes, array columns,
    top-level `add_index`.
  - Unknown DSL statements (`create_view`, `create_enum`, `create_function`,
    `add_check_constraint`) and unknown column types (PostGIS `st_point`,
    `geography`) become `skipped_statements` with a line number, never fatal.
    Views record which real tables their SQL body reads, so a view sitting on a
    table the plan builds can be told apart from one that is merely present.
  - `db/structure.sql` raises `SchemaFormatUnsupported` (exit 6) with the
    `db:schema:dump` workaround.
- `pinspec analyze` now prints the schema section, including inferred foreign
  keys and hazards, and names the sections still to come.

- **M-01 TargetParser** - resolves `FILE#METHOD` to a `TargetProfile` from a
  static Prism parse, loading no target-app code.
  - Constructor resolution across all six construction shapes (`:new`,
    `:class_method`, `:interactor`, `:dry_initializer`, `:struct`,
    `:model_instance`), including one level of superclass inheritance. This is
    the invocation surface spec v0.2 omitted, which made its own headline
    example unreachable.
  - Clean refusals with distinct exit codes: `BlockRequired` (4) for `yield` or
    `&block`, `UnresolvableSetup(:opaque_constructor)` (5) for a constructor
    that cannot be read statically or that resolves its own dependencies,
    `AmbiguousTarget` (3), `TargetNotFound` (2) carrying a delegation or
    `method_missing` redirect.
  - Static clock-site detection (`Time.now`, `Date.today`, arg-less `Time.new`,
    `DateTime.now`), including reads hidden in parameter defaults. Zone-aware
    reads are excluded by design.
  - Parameter kinds, default *source text* (never evaluated), and a name- and
    default-literal type hint.
- Exit-code taxonomy (spec v0.3 section 5.1), asserted through the real binary.
- `pinspec version` and `pinspec plan` (target resolution only; SetupPlan
  generation lands in M2). Every other verb names the milestone it arrives in.
- CI across Ruby 3.2/3.3/3.4, plus a run under `LANG=C LC_ALL=C TZ=Etc/GMT+8`.
- An ASCII-only guard over shipped string literals, because pinspec's own
  verification matrix runs under `LANG=C`.
