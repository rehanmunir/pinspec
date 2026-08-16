# Changelog

## 0.3.0 - 2026-08-15

More of a real codebase reachable, four things that were quietly wrong put right, and
294 fewer lines of code.

Measured across five public Rails applications (openfoodnetwork, chatwoot, mastodon,
forem, publishing-api — 841 service files), the share pinspec can plan a world for:

| | before | after |
|---|---|---|
| openfoodnetwork | 16% | 39% |
| chatwoot | 2% | 45% |
| mastodon | 10% | 76% |
| forem | 23% | 57% |
| publishing-api | 24% | 67% |
| **all** | **14%** | **53%** |

### Reaching more targets

- **The target method is discovered, not assumed.** `#call` is a convention, not the
  convention — chatwoot's entry points are named `perform`. pinspec counts the method
  names a directory actually uses and follows that application's own convention,
  falling back to `call`/`perform`/`run`/`execute`/`process`, then a class's only
  public method. Several plausible methods and no conventional one is a question, not
  a guess.
- **`def self.call(...)` delegating to `def call`** is the commonest service idiom in
  Ruby, and it made the bare name resolve to two definitions — 108 of forem's 322
  files were refused for it. The instance method is now named explicitly.
- **A class with no `initialize` has the default constructor, not an unreadable one.**
  Superclasses are resolved across the application's own files; only a constructor
  that exists and cannot be read is still refused. That one change took mastodon from
  10% to 76%.
- **Two type-hint rules.** In 222 of 222 parameters refused as unbuildable models, the
  "type" was just the parameter's own name capitalised — the refusal was rejecting
  pinspec's own guess. Names shaped like `create_params` or `options` are Hashes and
  plural names are Arrays, which are values pinspec can actually build.

### `pinspec verify SPEC_FILE`

Runs **any** spec file in the three environments, whoever wrote it. The Verifier never
knew where a spec came from, so this needed a command and nothing else. A spec
asserting `Time.now.strftime("%z")` passes where it was written and fails under
`hostile` — the failure a colleague's CI would have reported a week later.

### Fixed

- **`neighbored` never ran anything twice.** It passed the same path to RSpec twice,
  and RSpec loads a given path once — so the configuration silently re-checked what
  `isolated` checks, while the README claimed it caught accumulated state. It now runs
  a copy alongside the original, which really does execute the pin twice. On its first
  honest run it immediately found a real defect: **factory_bot sequences are
  process-global**, so a pin whose world uses one produced `INV-1` then `INV-2` and
  failed against its own snapshot. Both hosts now rewind sequences before every case.
- **`--boots 1` silently defeated the central claim.** One run has nothing to compare
  against, so every case was called stable by virtue of never being checked. Two is
  now a floor, not a default.
- **The emitted spec dropped a factory record's attributes and associations.** The
  probe passed them; the spec did not, so the two hosts built different worlds.
- **`--sample` bound to the factory record, not the sampled row.** Imports are now
  built first, so the real row the flag exists to fetch is the one the target receives.
- **`redact:` in `.pinspec.yml` was accepted and ignored.**

### Upgrading from 0.1.0 or 0.2.0

Nothing you already have stops working. Verified by generating pins with the real
0.1.0 and 0.2.0 and putting them through this version:

- **Pins written by 0.1.0 and 0.2.0 still verify green**, unchanged, including under
  the new honest `neighbored`.
- **Re-pinning one keeps its method and its filename.** Discovery follows the
  application's convention, which can differ from the `#call` older versions always
  assumed; where a pin already exists, the method it froze wins, so re-running cannot
  quietly write a second file and leave the first one in the suite.
- **Every flag those versions accepted is still accepted**, including `--skip-verify`
  and the `--app-env A=1 B=2` array form. `--snapshot` is taken and ignored with a
  note rather than rejected - it is no longer advertised, because a flag that does
  nothing should not invite use.
- **A `.pinspec.yml` naming a retired key warns and continues** instead of failing the
  build. A key that was never valid is still an error.
- **Exit codes mean what they always meant.** 11 (`EnvironmentRefused`) is retired and
  deliberately not reused, so a script testing for it simply never sees it.

`spec/upgrade_compatibility_spec.rb` holds all of this, so it cannot regress quietly.

### Deleted

294 lines net. Nothing here changes behaviour any user could observe:

- `Emit::Namer` (253 lines with its spec) — an LLM-backed description generator with
  an injectable client port, a prompt builder and an output sanitiser, reachable from
  nothing. There was no flag that turned it on.
- `--snapshot` — a flag whose entire implementation refused two of its own three
  values. Removed rather than given an abstraction to hang implementations on.
- `Sampler.choose_env` / `production_like?` / `guard_production!` and
  `EnvironmentRefused` — a guard for a path with no caller.
- `FactoryIndex#ancestry` / `#traits_for` / `#attributes_for` — one concept
  implemented twice; this was the copy nothing called.
- `Sandbox`'s `timeout:` and `runner:` seams (there is no timeout wrapper anywhere),
  `MAX_GENERATIONS`, and 31 of 41 `NON_MODEL_HINTS` entries that fire zero times.

### Added

- A **vacuous-pin caveat** in the report: a case that returned nothing, wrote no rows,
  enqueued nothing and sent nothing did run, but almost any change to the target would
  still satisfy it. These are exactly the pins that score weak.

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
