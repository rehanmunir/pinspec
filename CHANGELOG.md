# Changelog

## 0.1.0

The first published version. Spec v0.3 section 13 puts this cut at M1, after
`analyze`; it ships here instead, with M0 through M4 complete and M5's code in,
so that the first thing anyone installs can pin, verify and score rather than
only report hazards.

`pinspec pin FILE#METHOD --app PATH` captures a target's behaviour through a
generated probe inside the application, emits an RSpec file that needs no manual
edit, and verifies that file in three configurations. Proved end to end on two
real Rails apps on live PostgreSQL - Rails 7.2 on Ruby 3.3 under the transaction
regime, and Rails 6.1 on Ruby 3.1 under truncation - which are different enough
that agreement between them is evidence rather than coincidence.

M5's demo against a real open-source application has now been run too - against
Open Food Network, on live PostgreSQL - and it found nine defects that no fixture
had reached, including two that would have shipped wrong answers to a client. The
one bar it did not clear is aspect strength; the measurement and the reason are
below.

### M5: the demo against a real application, and the nine defects it found

Run against **Open Food Network** (`openfoodfoundation/openfoodnetwork`, Rails
7.2.3.2 on Spree, 93 tables, 801 columns, 124 foreign keys, 113 factories, 335
gems) on live PostgreSQL. The app is unmodified except for `.ruby-version`, which
was pointed at the Ruby installed here.

**Result: six service objects pinned, all three verify configurations green on
each, and all six passing together under the app's own `rspec`. About 14 seconds
per target.** One import cluster from real sampled rows. Zero literal database ids
in any pin.

Nine defects surfaced that no fixture had reached. Each is worth more than the
demo itself, because each was invisible to a suite written by the same person who
wrote the code:

1. **`analyze` crashed on any app with a non-ASCII byte, whenever the operator's
   locale was not UTF-8.** `File.read` tags its result with the LOCALE's encoding,
   so with `LANG` unset that is US-ASCII and the first `scan` over an accented
   comment raises `invalid byte sequence` - pointing at pinspec's own regex and
   saying nothing about the file. Every file pinspec reads belongs to somebody
   else, so all eleven read sites now go through `Analyzer::Source.read`, which
   reads UTF-8 and scrubs. `LANG` is unset in CI containers as a matter of course,
   and pinspec's own `:hostile` config sets `LANG=C` deliberately.
2. **A pin of pinspec's own failure to build a world, presented as the
   application's behaviour.** `Shop::OrderCyclesList.new(distributor, customer)`:
   no table is called `distributors`, so pinspec passed **nil**, the target raised
   `NoMethodError`, and that got pinned - green in all three configurations. This
   is the worst thing the tool can do, because the result is authoritative-looking
   fiction a reader cannot tell from a real characterization of a real bug. It now
   refuses with `UnresolvableSetup(:unresolvable_parameter)`, naming the parameter
   and the remedy. The guard runs before the early return that skips world-building
   entirely, because a target whose parameters ALL fail to resolve was reaching it
   only by luck.
3. **A false green: `0 examples` reported as a pass, three times over.** OFN has no
   `spec/rails_helper.rb` - the rails_helper/spec_helper split is a convention, not
   a rule - so the emitted spec could not load, and rspec reports a load failure as
   `0 examples, 0 failures` with exit 0. The verifier now names `:no_examples_ran`
   and `:spec_load_error`, and the writer requires the helper the app actually has.
4. **Engine-prefixed tables were unreachable from a parameter name.** `Spree::Order`
   lives in `spree_orders`, so a parameter named `order` resolved to nothing - and
   that is most of the commerce Rails pinspec exists for. The app states the mapping
   in its own factories (`factory :order, class: Spree::Order`), and a declared class
   is a fact rather than a convention. A schema-suffix fallback declines when
   ambiguous: OFN has both `spree_orders` and `proxy_orders`.
5. **The same blindness in the import path, from a second copy of one question.**
   `Inputs::Hydrator` had its own `model_for` that camelized the table name, so
   every imported row failed with `uninitialized constant SpreeOrder` while
   `DependencyResolver#model_for` next door already knew the answer. Two answers to
   one question is the bug class the analyzer modules were consolidated to avoid.
6. **The probe could not see 113 factories.** A real app bundles factory_bot with
   `require: false` and requires it from its spec helper, which `rails runner` never
   reads. The probe now loads it and finds definitions itself.
7. **A real app's factories are not deterministic, and a fixed seed makes that
   fatal.** OFN's `:user` factory draws an FFaker email, and its own validation is
   `valid_email_2` with **`mx: true` - a live DNS lookup**. pinspec pins `srand(42)`
   for reproducibility, which turned "usually passes" into "always fails". Fixed with
   a bounded retry in a new shared template (`templates/factory_build.rb`) embedded in
   the probe AND written beside the emitted spec: retrying costs no determinism,
   because both hosts start from the same seed, run the same loop, consume the same
   values and land on the same record.
8. **pinspec built a user record no target could observe**, unconditionally whenever
   devise was present - which meant running that flaky factory for every capture. It
   now builds one only when the target mentions a current user, and states the
   omission and its honest limit (a transitive callee is invisible to a file scan).
9. Smaller, all client-facing: a duplicated plan note, `Ruby: unknown` in a report
   header when the lock has no `RUBY VERSION` (`.ruby-version` answers it), an empty
   `Pinned file:` line, and `Gemfile.lock` still being read at the locale's encoding.

**Mutation-checked, and two lines deleted because of it.** 18 mutations over the
fixes above; all 18 killed after four rounds of closing gaps the first pass exposed.
Two of those gaps were not missing tests but dead code, which is the verdict this
project has now reached five times:

- The plan-note deduplication became unreachable once `whodunnit_step` reused the ref
  the auth step had already recorded, so the second `user_ref` call that produced the
  duplicate was gone. Removed rather than left as untestable defence.
- `Inputs::Hydrator`'s camelizing fallback for a model name only ever produced a
  wrong answer on the app that reached it. `factories:` is now required and nil is
  rejected, so forgetting it fails at the call site instead of surfacing as
  `uninitialized constant SpreeOrder` from inside the probe.

Coverage the demo also revealed was missing entirely: live sampling had no automated
test at all. `spec/runner/sample_wiring_spec.rb` now covers the sampler-to-hydrator
seam without needing a database, including status stratification and that no primary
key survives into a cluster.

**What the demo did NOT meet.** M5's definition of done asks for **>=60% of aspects
`:strong`**. Measured: `Paypal::ItemsBuilderService#call` scored **50% (weak)** and
`Orders::CaptureService#call` scored **16.7% (worthless)** - so 0% strong, not 60%.
That number is the finding, and it is a finding about pinspec: a boundary-value
corpus builds the *smallest* world that can exist, and the smallest world does not
reach the branches. CaptureService returns `false` at its first guard, so five
mutations survive; ItemsBuilderService's surviving mutant is an adjustments loop the
pinned order has no adjustments to exercise. Getting to `:strong` needs worlds built
to reach branches - which is what M-06's status-stratified sampling was for, and
which needs a populated database rather than boundary values. Reported rather than
tuned away.

### Fixed, both found by running pinspec's own suite somewhere other than the
### machine that wrote it

Neither of these was reachable from a green suite on one Ruby in one timezone,
which is the argument for the verification matrix in miniature.

- **The emitted pin's bytes depended on which Ruby pinspec ran on.** Ruby 3.4
  changed `Hash#inspect` to put spaces around the rocket, and the snapshot literal
  was delegating to it - so the same capture wrote `{"t" => "int"}` on 3.4 and
  `{"t"=>"int"}` on 3.3. Both parse to the same value, so nothing failed; but the
  pin is a **committed file**, and a tool whose promise is "re-run and nothing
  changes unless the behaviour changed" cannot hand two colleagues a diff on every
  line, or rewrite every pin in a repository because someone upgraded Ruby. The
  literal is now rendered by pinspec rather than delegated, and the emitted file is
  byte-identical across 3.2, 3.3 and 3.4.
- **A clock-dependent pin was reported as failed for anyone not in UTC.** Three
  places decided the timezone and they disagreed: the plan's fingerprint read
  `ENV["TZ"]` from the operator's shell, the probe forced `TZ=UTC`, and the
  verifier ran `:isolated` under `UTC`. So the fingerprint recorded a timezone the
  probe never used, the emitted spec's guard demanded that timezone, and the
  verifier contradicted it - a correct pin, reported as broken, on every machine
  east or west of Greenwich. It also made `plan_id` - content-addressed over the
  fingerprint - differ between two people pinning the same target from different
  desks, which quietly broke "the same target always yields the same plan".
  - The fingerprint now records the timezone the probe will actually run under,
    including an `--app-env TZ=...` override.
  - `:isolated` and `:neighbored` run under the capture's timezone, because "as
    captured" has to mean as captured.
  - `:hostile` picks a timezone that **differs** from the capture's. It was
    hardcoded to `Etc/GMT+8`, so for anyone who captured under `Etc/GMT+8` the
    hostile configuration was identical to the isolated one and reported green
    while proving nothing - in the one configuration whose entire job is to catch
    that.

### Added in the M4 completion pass

- **M-10 `Emit::Namer`**, the one place a language model is allowed near the
  output - and it is structurally kept away from values. The request carries a
  case id, an origin, an outcome *kind*, the method and class name, and parameter
  *names*: no pinned value can reach it because none is ever put in. A reply is
  then rejected if it contains a hash rocket, a serializer tag, `expect`, `eq(`,
  a three-or-more-digit number, or more than two quotes. Both walls are tested,
  the second by handing it a model that ignores every instruction. `--no-llm`
  remains the default and the deterministic namer is what runs.
- **M-11 `Validate::PinScorer`**, per-aspect mutation scoring, and the finding
  that justifies it: on the fixture target the return pin scored 66.7% and slept
  through a deleted `perform_later`, the job pin scored 50% and slept through the
  arithmetic, and **nothing survived every aspect**. A single number over the
  whole pin would have reported neither the blindness nor the coverage. Aspects
  absent from a pin are skipped rather than scored, since scoring an absent
  aspect yields a vacuous 100%; a pin containing `{"t":"seq"}` or a truncated
  value cannot be called strong however well it scores.
- **`Validate::MutationAdapter`**, the backend boundary from the M-11 spike. It
  selects by `qualified_name`, pairs `--strategy` to the runtime rather than
  letting the two be chosen independently, and leaves `GEM_HOME` alone while
  scrubbing bundler's variables - handing the app's gemset to the backend hides
  the backend from itself. Missing backend or Ruby below 3.4 refuses with a
  message that names the floor, the install, and what still works without it.
- **M-12 `Report::Summary`**, the markdown artifact a client reads instead of
  reading the pins. Organised so the caveats cannot be skipped: what was pinned,
  what was refused and why, which regime the reader has inherited, every place a
  pin asserts less than it appears to, what was rewritten out of imported rows,
  and hashed provenance. It states in its first paragraph that a pin is not a
  judgement that the behaviour is correct, because a reader who misses that will
  "fix" the pin.
- **Live sampling end to end** (`Inputs::SampleRunner`). The sampler now runs in
  the target app and its rows are hydrated into the plan. It is a separate
  process from the probe on purpose: it reads `development` while the probe writes
  under `RAILS_ENV=test`, and an empty database degrades to boundary values
  loudly rather than silently.
- **`pinspec validate` writes the report too**, which is what makes the report's
  mutation-scores section reachable at all - a branch nothing can reach is dead
  code, not defence in depth. A report written by `validate` has scores and no
  verification, so the verification section now says **"Not run in this pass"**
  rather than being omitted: an absent section reads as "nothing to say", and for
  verification that is a lie of omission.
- **M-14 HostEquivalence** as a build-breaking test over all six contract axes
  (`spec/equivalence/host_equivalence_spec.rb`). Each axis is set up to
  *disagree* with the plan - the fixture suite deliberately runs `:fr` and
  `Asia/Tokyo` - so a green pin proves the emitted spec forced the capture's
  answer rather than inheriting a matching one by luck. The clock axis asserts
  the opposite: a process-clock read must **fail** under a different timezone,
  and say why.


### Added in M4

- **M-09 SpecWriter, and the product's actual promise: a green RSpec file with
  zero manual edits.** `pinspec pin FILE#METHOD` now captures, emits and verifies.
  - The emitted spec **forces** the capture's answer on every axis rather than
    inheriting the suite's: the isolation regime, the `:test` queue adapter, the
    frozen clock, the seed, the locale and the zone. A suite that truncates instead
    of transacting, or that runs jobs inline, would otherwise turn a green capture
    into a red or vacuous spec.
  - `PinspecSerializer.normalize(value, refs:, fk_map:)` - the three-argument
    signature the review found v0.2 could not do with one. The serializer and the
    spec-host support module are written from `templates/`, the same files the probe
    embeds.
  - The return value is normalized **without** the returned record in the ref
    table and the side effects **with** it, because that is the order the probe
    uses. Getting this wrong made the record gain a `ref` key in one host and not
    the other - caught by the `:neighbored` verify config.
  - The TZ guard is emitted only for a target that reads the process clock.
    Guarding every pin would mean no pin survives a different timezone.
  - Job pins are block-scoped, so a factory's `after(:create)` enqueue is never
    counted as the target's.
  - Deterministic naming, no LLM involved - `--no-llm` is the default path.
  - pinspec overwrites its own output and nothing else: a file without the
    provenance header needs `--force` (spec section 12.6).
  - Zero literal database ids in an emitted pin, asserted by grep.
- **M-13 Verifier, as a three-configuration matrix**: `:isolated`, `:hostile`
  (different TZ, locale and RSpec seed) and `:neighbored` (the file twice in one
  process). All three green on the fixture app. A single isolated run measures
  repeatability, not portability, which was the point of the review's T1-6.
  Diagnoses are named, with an honest `:unknown` fallthrough.
- `pinspec pin` and `pinspec capture` take `--app-env KEY=VALUE`, for an app whose
  runtime is not this shell's - necessary precisely because the probe scrubs the
  parent's environment.

### Added in M3

- **M-07 ProbeGenerator, and the first code pinspec runs inside a target app.**
  A generated, stdlib-only script held to a Ruby 2.6 syntax floor, executed via
  `rails runner`. It refuses to run outside `RAILS_ENV=test`, wraps every case in
  a transaction and rolls it back, and can be read before it is run.
  - `templates/serializer.rb` is embedded verbatim and is the same file M-09 will
    write into the emitted spec. One source, two hosts (spec section 4c) from the
    start, rather than two copies to drift apart later.
  - **Identity never reaches a snapshot.** A foreign key pointing at a record the
    plan built becomes a ref; any other id-shaped value becomes `{"t":"seq"}`.
    Verified against live PostgreSQL: the row-30 target - a zero-argument `#call`
    returning a record it just created - is byte-identical across two boots.
  - Ids leak through two further channels that only a real run reveals. A bare
    `perform_later(record.id)` in a job's arguments, and a **GlobalID string**
    (`gid://app/Invoice/22`) from `deliver_later`, which hides an id inside a
    String where an integer index cannot see it. Both now resolve to the record
    they name, or keep the model and refuse the id.
  - Side-effect sinks are forced to `:test` and cleared after setup and before the
    target, so a factory callback's enqueue is never attributed to the target.
  - `SCHEMA`, `TRANSACTION` and cached SQL notifications are filtered, without
    which the first case to touch each model diverges from every later one.
  - Two boots by default. One process shares warm caches, so an input-keyed memo
    would agree with itself.
  - The parent's bundler environment is scrubbed. Running pinspec from inside its
    own bundle otherwise leaks `BUNDLE_GEMFILE` and `RUBYOPT` into the target app,
    which then resolves pinspec's Gemfile instead of its own and never boots.
- **M-08 StabilityFilter.** Joins the runs by case id over a declared field set -
  `duration_ms` and SQL fingerprints excluded, the latter unless SQL pins were
  asked for. Causes are named (`:identity_churn`, `:time`, `:float_noise`,
  `:setup_error`, `:escaped_transaction`, ...) with a capped diff excerpt, because
  "unstable" without a cause is an accusation and with one it is a lead.
- **`pinspec capture FILE#METHOD --app PATH`**, writing `observations.json`. Exits
  8 when nothing was stable, with a cause histogram.
- **`spec/fixtures/apps/rails71_basic`**, a Rails 7.2 app on PostgreSQL that
  really boots, with a factory, a job, a mailer, and the row-30 target. The
  integration specs skip rather than fail when it has not been prepared.
  Rollback is proved by row count, not by assertion in prose.

### Added in M2

- **M-06 inputs** - the corpus, the redactor, the hydrator, and the sampler.
  - `Tags`, the serializer-v3 vocabulary. Every value crossing the JSON boundary
    is tagged, including the ones JSON could carry: a bare `5` would be ambiguous
    between an Integer and a whole decimal, and the probe would have to guess.
    NaN, infinities and binary strings get their own tags rather than being
    coerced to null or making `JSON.generate` raise.
  - **Boundary values and OFAT** across constructor *and* method parameters,
    interleaved so a budget cannot be spent entirely on the constructor. One
    all-defaults case first, then one parameter varied per case. An optional
    argument is also omitted entirely in one case, which runs the method's own
    default expression - and a default can read the clock or a feature flag.
  - Parameter typing by precedence: the declared default literal, then a schema
    column of the same name, then the name-derived hint. An ambiguous column type
    is declined rather than guessed.
  - **Redaction, domain- and length-preserving**, which is the whole difference
    from v0.2's `user1@example.test`: an email keeps its domain and its length,
    a phone keeps every separator, an SSN keeps its shape. A redactor that
    changes behaviour is worse than none, because it looks correct. Read
    detection flags and notes it when the target actually reads a rewritten
    attribute.
  - **Hydration** of sampled rows into `ImportCluster`s at plan time: primary
    keys and volatile columns dropped, foreign keys rewritten to refs, refs
    namespaced away from the ones the plan creates, depth and row caps, a
    nullable cross-cluster parent nulled and a required one discarded with a
    note, and hashed provenance so a committed spec does not map to production
    row ids.
  - **The sampler** runs as a generated, read-only, stdlib-only script inside the
    target app - the same architecture as the probe, so pinspec needs no database
    gem and works on any adapter. Deterministic quartile offsets rather than
    random sampling. The environment default is now development-if-populated,
    reversing v0.2's default to the empty test database. A production-looking
    name refuses until confirmed.
  - CI's Ruby 2.6 probe-syntax guard is live: `spec/fixtures/probe/sampler_snapshot.rb`
    is a committed rendering, syntax-checked on 2.6 and asserted against the
    generator so it cannot go stale.
- `pinspec plan` now prints the input cases alongside the plan, and takes
  `--cases N`.

### Added in M2 (continued)

- **M-05 ContextBuilder** - TargetProfile + AppProfile =>
  SetupPlan. Pure data in, pure data out: no connection, no app code, no app
  process, so a plan is readable before anything runs.
  - The environment is pinned before any record exists: frozen clock, seeded
    randomness, locale and zone. A `created_at` written before the clock is frozen
    is a value nobody can pin.
  - `isolation` is carried onto the plan from the app profile, so both hosts share
    one regime rather than assuming each other's.
  - A factory is used when one exists and persists, and is then left to own its own
    associations; otherwise the required `belongs_to` closure is built explicitly
    and wired through `assoc_refs`. A factory that never persists is declined with
    a note rather than failing inside the probe.
  - Nullable associations are left null - the smallest world that can exist is the
    one least likely to surprise a reader.
  - One record per model-typed *parameter*, not per table: two `Company`
    parameters are two companies, because binding both to one row would build a
    world where a company merges with itself.
  - Deterministic uniquifiers namespaced by plan generation, so a re-plan after a
    seed-data collision cannot collide the same way twice.
  - Temporal columns are filled from the plan's frozen instant, and string
    placeholders respect a column's length limit.
  - Tenant, current-user and paper_trail whodunnit steps, each ordered after the
    record it references and sharing one user record.
  - `:construct_subject` carries the class and construction kind but not the
    argument values: a plan is per-target and cases are per-case, so putting
    values here would be a category error.
  - Refusals, each naming the wall: `:apartment`, `:unknown_column_type` (the
    refusal M-02 deferred until a plan needed the table), `:association_cycle` for
    two tables that require each other and for a NOT NULL foreign key to a table's
    own row.
  - `plan_id` is content-addressed over the steps, isolation, generation and
    environment, so the same target always yields the same plan and a changed plan
    is visibly a different one.
- `pinspec plan FILE#METHOD --app PATH` now renders the SetupPlan, its parameter
  bindings, and its notes.

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
