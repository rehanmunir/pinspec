# Changelog

## 0.2.0 - 2026-08-15

Ergonomics. 0.1.0 worked, but a run against a real application needed six lines of
environment before it would start, and almost none of it was intent.

### The app's Ruby is detected, not declared

pinspec reads the target application's `.ruby-version` or `.tool-versions` and
locates that Ruby under rvm, rbenv, asdf, mise or chruby on every run. Only
bundler's variables are scrubbed from the child process now; `GEM_HOME` and
`GEM_PATH` are left alone, which is what previously forced every invocation to hand
the application's gemset back by hand. When the declared Ruby cannot be found,
the failure names the version, the one in use, and the exact `--app-env` line to
pass.

A patch-level difference is treated as the same runtime: 3.4.2 and 3.4.6 run the
same code, and relocating for it would fail on a machine that has only one.

### `.pinspec.yml`

`pinspec init` writes it. It holds the flags you would otherwise repeat - `cases`,
`boots`, `sample`, `verify-level`, `test-command`, and an `env` mapping for what
pinspec cannot work out, such as database credentials. A flag on the command line
always wins. An unknown key is an error naming the key and listing the valid ones,
rather than silence that reads as "the setting does not work".

The detected runtime is deliberately **not** written to that file: recording one
machine's `PATH` bakes in a layout that goes stale the moment the app changes Ruby,
and detection re-runs anyway.

### Targets

- A bare file assumes `#call`: `pinspec pin app/services/invoice_calculator.rb`.
- `--app-env` is repeatable (`--app-env A=1 --app-env B=2`) instead of an array
  option, so the target can appear anywhere on the line. As an array option it
  silently swallowed the positional target unless that came first.

  **The 0.1.0 form keeps working.** `--app-env A=1 B=2 C=3` was what 0.1.0
  documented, and changing the option type would have silently reinterpreted every
  existing invocation rather than failing on it. Trailing `KEY=VALUE` pairs are
  still collected, the target is whichever argument is not a pair, and using the old
  form prints a note suggesting the new one. Nothing anyone scripted against 0.1.0
  needs to change.
- **A directory pins everything under it.** Refusals are reported and the run
  continues, since one target that takes a block should not end a run over forty.
  The summary separates what was pinned, what was skipped and why, and what failed
  verification. Exits non-zero when nothing pinned.

### Output

Default output is the target, the stable count, what was pinned, the three verify
results and the report path. The plan id, compared fields and per-case detail move
behind `--verbose`. `pin` leads the command list, and `plan` and `capture` are
labelled diagnostics.

### Compatibility

Nothing from 0.1.0 breaks. Both `--app-env` forms are accepted, `FILE#METHOD` still
works alongside the new bare-file shorthand, every flag keeps its name and meaning,
and `.pinspec.yml` is optional - an application without one behaves exactly as it
did, except that its Ruby is now found automatically.

### Fixed

- **Two pinspec runs against the same application corrupted each other.** The probe
  was written to a fixed `tmp/pinspec/probe.rb`, so a second run overwrote it between
  the first run's two boots. The failure was silent rather than loud: the stability
  filter compared one target's observations against another's and reported the target
  as unstable, or crashed looking up a case id belonging to a different corpus. Each
  run now writes its own probe, named after the process, and removes it on success -
  keeping it after a failure, where it is the evidence. Found by running two captures
  against one application at once.
- Batch discovery matched its skip patterns against the absolute path, so an
  application living anywhere under a directory named `spec` had every file skipped.
  Patterns now match the path relative to the directory being pinned.
- `analyze` did not read `.pinspec.yml`, so a typo in it stayed silent for the
  command people run first.

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
