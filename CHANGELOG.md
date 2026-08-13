# Changelog

## 0.1.0 - 2026-08-13

First release.

`pinspec pin FILE#METHOD --app PATH` resolves a Rails service object or model
method, builds the world it needs, runs it inside the application, writes an RSpec
file that freezes what it observed, and verifies that file in the application's own
test environment.

### Commands

- `analyze` - application profile, schema, factories and hazards. Static: no boot,
  no database connection.
- `plan` - the world pinspec would build and the arguments it would pass. Pure data,
  readable before anything runs.
- `capture` - runs the generated probe in the application and writes
  `observations.json`.
- `pin` - capture, emit the spec, verify it.
- `validate` - mutation-scores a pin one aspect at a time. Requires Ruby >= 3.4 and
  `mutineer`; refuses with an explanation otherwise.
- `report` - the markdown report from the last run.

### Analysis

- Targets resolve from a static parse across six construction shapes: `new`, class
  method, interactor, `dry_initializer`, `Struct` and model instance, including one
  level of superclass inheritance. Constructor arguments are part of the invocation
  surface, so a zero-argument `#call` whose dependencies arrive via `initialize` is
  supported.
- `db/schema.rb` is parsed into tables, columns, indexes and a foreign-key map with
  provenance: a database constraint, a declared association, or an inferred `*_id`
  column. Constraints win over inferences, and inferences are reported separately.
  Polymorphic ids are excluded.
- Association targets resolve against the schema's real table names rather than by
  pluralising, and tables behind an engine prefix are found through the class a
  factory declares - so `Spree::Order` resolves to `spree_orders`.
- factory_bot and factory_girl definitions are indexed from source and never
  executed, including traits, inheritance through nesting and `parent:`, callbacks,
  and factories that never persist.
- Gem, auth, tenancy, soft-delete, versioning, feature-flag, attachment and
  test-harness detection from `Gemfile.lock` and the helper files, with per-model
  hazards (`default_scope`, `after_commit`, attachments, `acts_as_tenant`) reported
  by file and line.
- Unknown schema statements and column types are recorded rather than fatal.

### Planning and inputs

- A `SetupPlan` is pure data: no connection, no application code, no application
  process. Its id is content-addressed, so the same target always yields the same
  plan and a changed plan is visibly different.
- The environment is pinned before any record exists: frozen clock, seeded
  randomness, locale, time zone.
- A factory is used where one exists and is then left to own its own associations;
  otherwise the required `belongs_to` closure is built from the schema. Nullable
  associations are left null.
- A current-user record is built only for a target that could observe one.
- Boundary values and one-factor-at-a-time variation across constructor and method
  parameters, interleaved so a small case budget reaches both. One case omits an
  optional argument entirely, exercising the method's own default expression.
- `--sample` reads real rows through a generated read-only script in the
  application's runtime, then rebuilds them as `create!` calls. Personal data is
  rewritten preserving domain and length; row sources are hashed.

### Capture

- The probe is generated, stdlib-only, and held to a Ruby 2.6 syntax floor, so it
  runs in the application's Ruby. It can be read before it is run.
- It refuses to run outside `RAILS_ENV=test`, and honours the suite's isolation
  regime - rolling back per case, or truncating where the suite does not transact.
- No database id reaches a snapshot. Foreign keys pointing at plan-built records
  become refs; other id-shaped values become a wildcard. Ids inside job arguments
  and GlobalID strings are resolved too.
- Side-effect sinks are forced to `:test` and cleared after setup, so a factory
  callback's enqueue is never attributed to the target.
- Two boots by default, because one process shares warm caches and an input-keyed
  memo would agree with itself. Cases that differ between boots are reported with a
  named cause rather than pinned.

### Emitted specs

- The spec forces the capture's answer on every axis rather than inheriting the
  suite's: isolation regime, queue adapter, clock, seed, locale and zone.
- Verification runs in three environments - the file alone, a hostile timezone and
  locale with a different seed, and the file twice in one process.
- Job and mail assertions are block-scoped. A timezone guard is emitted only for a
  target that reads the process clock.
- pinspec overwrites only its own output; anything else needs `--force`.
- Example names are deterministic. No captured value is sent anywhere: there is no
  path from the CLI to a language model.

### Refusals

Each carries its own exit code: a target that takes a block, a constructor that
resolves its own dependencies, a parameter naming a model the application has no
table, model or factory for, mutually required NOT NULL foreign keys, a NOT NULL
column whose type has no honest value, attachments, `ros-apartment` tenancy, an
ambiguous target name, a delegation or `method_missing` redirect,
`db/structure.sql`, Rails below 6.0, and nothing stable to pin.

pinspec does not pass `nil` for a model it could not build: the target would raise
on nil and that error would be pinned as though the application produced it.

### Known limitations

- Mutation scores on real service objects are frequently weak. The default corpus
  builds the smallest world that can exist, and the smallest world often does not
  reach a target's branches. Read the scores before trusting a pin; `--sample`
  helps.
- `after_commit` never fires under transactional isolation, in the capture or in the
  emitted spec. pinspec does not fake it, and the report says so.
- Per-case rollback covers the primary writing connection only.
- Attachments are refused rather than run against an empty blob.
- Clock and attribute-read detection scans the target's own file, so a transitive
  callee is invisible. No warning is not proof of no read.
- `insta` and `approvals` snapshot backends are not implemented; `--snapshot`
  refuses them rather than silently emitting inline literals.

### Requirements

Ruby >= 3.2 for the CLI, and >= 3.4 for `validate`. Rails >= 6.0 in the target
application. No database gem is added: everything that touches application data
runs inside the application through `rails runner`.

### Verified

658 examples on Ruby 3.4.6, 3.3.0 and 3.2.2, each under a normal shell and under
`LANG=C LC_ALL=C TZ=Etc/GMT+8`. Both isolation regimes are covered end to end by
Rails applications that boot on PostgreSQL, and the six axes on which the probe
process and the spec process could disagree are held to agreement by a test that
fails the build. Also exercised against a large open-source Rails application on
Spree: six service objects pinned, each green in all three verify configurations.
