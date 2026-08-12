# pinspec — Rails Characterization Harness

**Technical Specification v0.3 — August 2026** (supersedes v0.2)
Gem name **locked: `pinspec`** · module `Pinspec` · executable `pinspec`. (`pinion` is squatted on rubygems.org — cespare/pinion, Rack asset compiler, v0.3.2, 2013, ~50k downloads. v0.1/v0.2 prose calling the project "Pinion" refers to this same project; Task 0 is closed.)

---

## 0. Changelog v0.2 → v0.3

v0.2's organizing principle — *one serializer, two hosts* — was right and under-applied. It was enforced for value encoding and **assumed** for the three other things that also live in two hosts: record identity for target-created records, transactional isolation, and side-effect sink lifecycle. Each was the v0.1 failure class in a different hat. v0.3 promotes the principle to **one contract, two hosts** across six axes, adds the missing invocation surface, and makes the verifier measure portability instead of repeatability.

### Eight breaking contract changes

1. **Constructors exist.** `TargetProfile += :initializer_params, :construction_kind`; `InputCase += :ctor_args, :ctor_kwargs`; `SetupPlan += :construct_subject`. v0.2's headline example (`pinspec pin app/services/invoice_calculator.rb#call` — a zero-arg `call` on a class whose `initialize` takes the invoice) was unreachable: nothing parsed `initialize` and M-05 built a subject only for *model* instance targets. (§6, §7 M-01/M-05/M-06, row 29.)
2. **Identity covers target-created records.** `cases.json += fk_map`; the serializer rewrites FK attributes → refs on **every** AR instance, not only plan-created/imported ones; unresolvable id-shaped values get the new `{t:"seq"}` wildcard; `StabilityFilter += :identity_churn`. Postgres sequences do not roll back, so v0.2 dropped "returns the record it created" — the most common service-object shape — as `:external_io`-unstable. (§6, §9, §7 M-02/M-07/M-08, rows 30, 12.)
3. **Isolation is a plan property, not an assumption.** `SetupPlan += :isolation` (`:transaction` | `:truncation`), derived from `AppProfile#db_cleaner` / `use_transactional_fixtures`; SpecWriter emits a matching wrapper; M-13 gains `:isolation_mismatch` with a flip-once remedy. v0.2 detected DatabaseCleaner truncation and then only used it for post-hoc diagnosis, while row 17 claimed `after_commit` was suppressed "consistently in probe *and* spec" — false under truncation. (§7 M-05/M-09/M-13, rows 17, 31.)
4. **Stability compares a declared field set.** §10 filters `SCHEMA`, `TRANSACTION`, and `payload[:cached]` notifications; §8 names exactly which `Observation` fields participate (SQL and `duration_ms` excluded by default). v0.2's "deep-compare" over the whole record made the first case touching each model diverge from run 2 — a day-one everything-is-unstable bug. (§7 M-08, §10, row 32.)
5. **Imports bypass validations and callbacks.** `:import_record` uses `insert_all` + refetch + attribute diff (`:import_mutated` flag). v0.2's `create!` could not import legacy rows that fail today's validations — the exact rows worth importing — and its callbacks silently rewrote imported attributes. (§7 M-06/M-07, row 33.)
6. **A declared Rails floor: 6.0.** v0.2 pinned a Ruby floor (probe 2.6-safe) and never a Rails floor while relying on `insert_all`, `connects_to`, and `CurrentAttributes#reset_all`. Below 6.0 → clean refusal. (§0.1, §12.11.)
7. **Verification is a 3-configuration matrix.** `:isolated` / `:hostile` / `:neighbored`. v0.2's M-13 proved same-machine repeatability and called it portability; TZ, fresh sequences, collation, parallel workers, accumulating deliveries, suite contamination, and RSpec ordering were all invisible to it. M4's DoD also gains a **positive-coverage** assertion — v0.2's "zero literal ids (grep-able)" passes trivially when zero pins were emitted. (§7 M-13, §13, §14.)
8. **`PinspecSerializer.normalize(result, refs:, fk_map:)`.** v0.2's one-argument `normalize(result)` could not do the thing §4c was built around: resolving a live AR instance to `{t:"ref"}` requires the spec's own ref table. (§7 M-09.)

### Decisions reversed

| v0.2 (locked) | v0.3 | Why |
|---|---|---|
| Run-2 shuffle default; `--paranoid` two-boot opt-in | **Two boots default; `--fast` for in-process shuffle** | Run 2 inherits run 1's warm caches. An input-keyed memo (`@rate ||= compute(customer)`) filled by run 1's first case is reused by all of run 2 → both runs agree, pin value is an ordering artifact. Determinism is goal #3; a boot costs 10–30s. |
| Sample DB defaults to app **test** DB | **`development`-if-populated, else `test`, loudly reported** | Test DBs are empty, so the default silently disabled import clusters, sampled cases, and stratified coverage — the whole v0.2 hydration rewrite — while M5's DoD requires an import cluster. Plan-time hydration is what makes cross-env sampling safe. |
| Redaction ON, "format-preserving" | ON, **domain- and length-preserving**, + read detection | `user1@example.test` changes domain routing, allowlists, and `split("@").last`. `Person7` changes string length. A report footnote does not fix a wrong pin. |
| §4c "one serializer, two hosts" | **§4c "one contract, two hosts"** across encoding · isolation · sinks · clock · locale · zone, with a per-axis CI equivalence test (**new M-14**) | The three unenforced axes are where v0.2 broke. |

### New module

**M-14 HostEquivalence** — pinspec's own CI harness: for each of the six contract axes, run the probe and the emitted spec against the same fixture target and assert identical observations. Turns "the two hosts agree" from a design intention into a build-breaking test.

### Enhancement pass, by module

M-01 constructor resolution (5 shapes) + `Time.now`/`Date.today` site detection · M-02 emits `fk_map` · M-04 `use_transactional_fixtures`, Rails-floor check, `time_now_sites` · M-05 `:construct_subject`, `:isolation`, `:env_fingerprint`, **quarantine-first** replan, import-aware uniqueness remedy · M-06 redaction rework + read detection · M-07 identity map, FK rewriting, `insert_all` import, SCHEMA filtering, two-boot default · M-08 declared compare set + `:identity_churn` · M-09 `normalize` signature, isolation wrapper, forced adapters, per-example deliveries clear, block-form matchers, TZ guard · M-11 **spike pulled forward to M1** · M-12 new sections · M-13 matrix + 4 new diagnoses. Matrix grows rows 29–37. Schedule moves from 6–8 to **10–13 weekends** (arithmetic in §13; the increase over the review's 8–12 is M-14 plus the fixture-app line item v0.2 never costed).

### 0.1 Version floors (new, normative)

| Component | Floor | Reason |
|---|---|---|
| CLI Ruby | 3.2 | `Data.define`, prism |
| Probe Ruby syntax | 2.6 | oldest Ruby a supported Rails runs on; CI `ruby -c` guard |
| **Target Rails** | **6.0** | `insert_all` (import), `connects_to` (multi-DB detect), `CurrentAttributes#reset_all` (between-case clears) |
| Target RSpec | 3.x with `rspec-rails` | emitted spec host; `have_enqueued_job` block matcher |

Below the Rails floor: `UnsupportedRailsVersion` (exit 10) naming the detected version and the three APIs that are missing. Supporting 5.2 means a hand-rolled multi-row insert and a `CurrentAttributes` shim — deliberately out of v1 (open question 10).

---

## 1. Problem statement

Unchanged from v0.2. Legacy Rails codebases can't be refactored safely because nobody knows what the code currently does, and hand-writing characterization tests means manually constructing factory setups, guessing inputs, and copy-pasting outputs for hundreds of methods. Skunk ranks what to test, Keploy captures the HTTP boundary, Insta/approvals store snapshots, mutant/mutineer validate suites — nothing takes a Rails service object, figures out how to invoke it, executes it, and emits an idiomatic pinned spec. Diffblue proved the category for Java; Ruby has no entrant.

**One-sentence product:** `pinspec pin app/services/invoice_calculator.rb#call` → a green RSpec file that freezes current behavior, validated by mutation testing.

## 2. Goals (v1)

1. A passing characterization spec for a Ruby service object or model method with **zero manual edits** on a real-world Rails app — proven by the M-13 verification *matrix* (§7 M-13), not by a single isolated run.
2. Setup inference handles the top Rails patterns (edge-case matrix, §11, now 37 rows) without user configuration.
3. Every emitted pin is deterministic: same inputs → same snapshot **in a fresh process, a hostile environment, and alongside other specs**.
4. Pins are graded per aspect: mutation testing labels return / error / jobs / mail / sql pins strong, weak, or worthless independently.
5. LLM touches **only** names, grouping, and prose. Never expected values — structurally, not by instruction.

## 3. Non-goals (v1)

Unchanged from v0.2: HTTP-level recording (Keploy) · production traffic capture and parallel-run (Scientist, P2) · whole-repo bulk mode (P2, Skunk-driven) · correctness judgment (bugs get pinned on purpose) · controllers, views, jobs, channels · Minitest output (P2) · symbolic execution / RL input search.

**`after_commit` fidelity, restated.** v0.2 declared this a non-goal and then claimed consistent suppression across hosts, which was untrue under DatabaseCleaner truncation. v0.3's position: we do not *fake* commit callbacks, and we do not *assume* the two hosts agree about them — isolation is an explicit plan property (§7 M-05 rule 13) so that whichever regime is in force, both hosts are in the same one, and the report says which. Under `:transaction`, `after_commit` never fires in either host and the divergence from production is documented per §12.7. Under `:truncation`, it fires in both and the capture mutates the test DB, which the report also says.

## 4. Architecture

Three load-bearing decisions; (c) is restated and broadened.

**(a) Two processes, two gemsets.** The CLI runs in its own gemset (Ruby ≥ 3.2, prism, thor). The probe is a generated, **stdlib-only** Ruby script (`json` alone) executed inside the target app via `bundle exec rails runner`. Probe syntax floor: Ruby 2.6. Zero gems added to a client Gemfile.

**(b) All execution happens against the app's test DB.** The sample DB is a read-only *source of attribute hashes*, consumed at plan time in the CLI process. The probe and the emitted spec build identical worlds from the same SetupPlan — that is what makes snapshots portable.

**(c) One contract, two hosts.** Six axes must agree between the probe process and the emitted-spec process. Each is generated from a single source and each has a CI equivalence test (M-14):

| Axis | Mechanism | Enforced how |
|---|---|---|
| **Encoding** | serializer v3 rules (§9) | probe encoder + `PinspecSerializer` helper generated from `templates/serializer.rb.erb` |
| **Isolation** | `SetupPlan#isolation` | probe wraps/doesn't; spec emits matching `around` hook that overrides the suite's strategy |
| **Sinks** | ActiveJob `:test` + ActionMailer `:test`, cleared after setup / before target | probe forces + clears; spec forces in `around`, clears in `before`, asserts via **block-form** matchers |
| **Clock** | one `travel_to` call site, `with_usec` behavior pinned | same template constant in both hosts |
| **Locale** | `I18n.locale` from `:set_locale` | plan step + spec `around` |
| **Zone** | `Time.zone` from `:set_zone`; process `TZ` **guarded, not settable** | plan step + spec guard that fails loudly when `ENV["TZ"]` ≠ capture-time value |

The zone row is the honest asymmetry: an emitted spec cannot set its own process `TZ` before Rails boots, so `Time.now`-using targets are flagged (M-01), guarded (M-09), and exercised by the `:hostile` verification config (M-13) rather than pretended away.

```
┌────────────────── pinspec CLI (own gemset, Ruby ≥ 3.2) ─────────────────┐
│                                                                         │
│ analyze:  TargetParser ─┐                                               │
│           SchemaReader ─┼──► AppProfile ──► ContextBuilder ──► SetupPlan │
│           FactoryIndex ─┘        (+fk_map)       ▲             │        │
│                                                  │ replan      │        │
│ inputs:   Sampler(sample DB, read-only,          │ (≤3, only   │        │
│           plan-time hydration) ──► InputCorpus ──┤  if ALL     ▼        │
│                    (ctor ∪ method params)        │  cases fail)         │
│                                                  │      ProbeGenerator  │
└──────────────────────────────────────────────────┼──────┼──────────────┘
                            all-cases setup_error ─┘      ▼
   target app dir:  DISABLE_SPRING=1 TZ=UTC RAILS_ENV=test \
                    bundle exec rails runner tmp/pinspec/probe.rb
   (app's own Ruby + gems; probe = stdlib json only)
   run 1 + run 2 = TWO BOOTS by default, shuffled within each
                                                          │
                                                          ▼
┌──────────────────────────── back in CLI ────────────────────────────────┐
│  StabilityFilter ──► SpecWriter (+SnapshotAdapter, +serializer helper)  │
│    (declared field set)   │                           │                 │
│                    Namer (LLM: names only)            ▼                 │
│                                        M-13 Verifier — 3 configs:       │
│                                        isolated · hostile · neighbored  │
│                                        diagnose, remedy-retry ≤1        │
│                                                       │                 │
│  MutationAdapter (opt-in) ──► PinScorer ──► Report ◄──┘                 │
└─────────────────────────────────────────────────────────────────────────┘
```

## 5. CLI surface

```
pinspec analyze [APP_PATH]              # M1 — app profile: schema, factories, auth, tenancy, hazards
pinspec plan    FILE#METHOD             # M2 — print SetupPlan (incl. ctor + import clusters), no execution
pinspec capture FILE#METHOD [options]   # M3 — run probe, write observations.json
pinspec pin     FILE#METHOD [options]   # M4 — plan + capture + emit + verify (the main verb)
pinspec validate SPEC_FILE              # M5 — mutation-score existing pins
pinspec report                          # dump last run's markdown report

Options:
  --app PATH             target app root (default: cwd)
  --cases N              max input cases per method (default: 12, spans ctor ∪ method params)
  --snapshot BACKEND     inline | insta | approvals (default: inline)
  --sample-db URL        read-only DB for input sampling
                         (default: development if populated, else test — reported either way)
  --isolation MODE       transaction | truncation (default: inferred from the app's test config)
  --validate             run mutation scoring after pin (NOT counted in the <5 min/target budget)
  --no-llm               deterministic names, skip API call
  --fast                 run 2 in-process with shuffled order instead of a second boot
                         (cannot detect first-touch memoization — see §7 M-07)
  --no-redact            disable PII redaction on imported rows (loud warning + confirm)
  --no-side-effects      don't pin enqueued jobs / mail deliveries
  --verify-level LEVEL   full | isolated (default: full = 3-config matrix)
  --skip-verify          emit without running M-13 (CI-less environments)
  --max-collection N     relation/array materialization cap (default: 50)
  --dry-run              print generated probe + plan, execute nothing
  --unsafe-env ENV       allow non-test RAILS_ENV (interactive confirm, or PINSPEC_UNSAFE_CONFIRM=1)
```

### 5.1 Exit codes (new, normative)

A scriptable CLI needs these enumerated, and M-01's acceptance already depends on two of them being distinct.

| Code | Meaning |
|---|---|
| 0 | success — `pin` reached `:green` or `:remedied` on every requested verify config |
| 1 | generic failure |
| 2 | `TargetNotFound` (message names the `delegate to:` receiver when resolvable) |
| 3 | `AmbiguousTarget` |
| 4 | `BlockRequired` |
| 5 | `UnresolvableSetup` (reason in message: `:association_cycle`, `:attachment`, `:opaque_constructor`, `:unknown_column_type`, `:apartment`) |
| 6 | `SchemaFormatUnsupported` (`structure.sql`) |
| 7 | probe boot or crash failure (app didn't load) |
| 8 | `NothingStableToPin` — all cases unstable or quarantined; report names the causes |
| 9 | `VerifyFailed` — emitted, not green; diagnosis in report |
| 10 | `UnsupportedRailsVersion` |
| 11 | `EnvironmentRefused` — non-test env without confirm |
| 12 | `PinspecInternalError` — our bug; verbose dump, never blamed on the user |

## 6. Core data structures

Immutable value objects (`Data.define` in the CLI; plain hashes across the JSON boundary). Δ marks v0.3 changes.

```ruby
TargetProfile = Data.define(
  :file_path, :class_name, :method_name,
  :params,               # [Param(name:, kind: :req|:opt|:key|:keyreq|:rest, default_source:, type_hint:)]
  :initializer_params,   # Δ same Param shape; [] for class-method targets
  :construction_kind,    # Δ :new | :class_method | :interactor | :dry_initializer | :struct | :model_instance
  :visibility,           # :public | :private (private → warn, invoke via send)
  :takes_block,          # true → BlockRequired; blocks can't cross the JSON boundary
  :source_range,         # [start_line, end_line] — handed to mutation adapter
  :referenced_constants, # Δ now load-bearing: feeds flag, attachment, and clock detection
  :clock_sites           # Δ [{call: "Time.now"|"Date.today"|"Time.new"|"DateTime.now", line:}]
)

SchemaGraph = Data.define(:tables, :fk_map, :skipped_statements)
# Δ fk_map: {"invoices.customer_id" => "customers", ...} — from references/belongs_to expansion
#   ∪ add_foreign_key ∪ *_id columns whose stem matches a table name (heuristic, marked as such).
#   Shipped into the probe; without it the probe cannot tell a foreign key from a quantity.
# skipped_statements: [{kind:, file:, line:, relevant: bool}]  # Δ relevant = touches a planned table

FactoryIndex = Data.define(:factories, :legacy_dsl)   # legacy_dsl: true when factory_girl

AppProfile = Data.define(
  :rails_version, :ruby_version, :rails_floor_ok,     # Δ rails_floor_ok: >= 6.0
  :auth, :authz, :tenancy, :soft_delete,
  :versioning,   # :paper_trail | :none
  :flags,        # :flipper | :none
  :attachments,  # [:active_storage, :carrierwave, :paperclip]
  :multi_db, :spring,
  :after_commit_models,        # [{model:, file:, line:}]
  :default_locale, :default_zone,
  :db_cleaner,                 # :transaction | :truncation | :none
  :transactional_fixtures,     # Δ use_transactional_fixtures / use_transactional_tests value
  :queue_adapter_in_tests,     # Δ :test | :inline | :sidekiq | :unknown — from rails_helper/env grep
  :test_stack, :schema, :factories
)

SetupPlan = Data.define(:steps, :isolation, :env_fingerprint, :plan_id)
# Δ isolation: :transaction | :truncation  — derived, overridable via --isolation
# Δ env_fingerprint: {tz:, locale:, zone:, rails:, ruby:, serializer: 3} — stamped into probe + spec;
#   the spec's TZ guard compares ENV["TZ"] against env_fingerprint[:tz]
# steps: ordered SetupStep(kind:, payload:)
#   :create_record     {factory:|model:, name:, attrs:, assoc_refs:}
#   :import_record     {model:, name:, attrs:, source: "sample:invoices:<sha1_8>"}
#                       — attrs FK-rewritten to refs + PII-redacted at hydration
#   :construct_subject {class:, args:, kwargs:, kind:}    # Δ the missing invocation surface
#   :set_tenant        {record_ref:}
#   :stub_current      {kind: :devise_user | :current_attributes, record_ref:}
#   :set_locale {locale:}   :set_zone {zone:}
#   :set_flag   {flag:, enabled:}      :set_whodunnit {record_ref:}
#   :freeze_time {at: ISO8601}         :seed_random {seed: 42}

InputCase = Data.define(:id, :ctor_args, :ctor_kwargs, :args, :kwargs, :origin)
# Δ ctor_*: constructor inputs; origin: :sampled | :boundary | :stratified | :defaults
InputCorpus = Data.define(:cases, :setup_plan)

Observation = Data.define(
  :case_id, :run,             # run: 1 | 2 (separate boots by default)
  :status,                    # :returned | :raised | :setup_error
  :return_value,              # serialized per §9, when :returned
  :error,                     # {class:, message:} when :raised — raises are pins too
  :setup_error,               # {step_index:, error: {class:, message:}}
  :enqueued_jobs,             # [{job:, queue:, args: serialized}]
  :mail_deliveries,           # [{to:, subject:}]
  :sql_fingerprints,          # normalized, ordered; §10 filters applied
  :db_delta,                  # {inserts:, updates:, deletes:} — ATTEMPTED writes, see §10.1
  :flags,                     # Δ see below
  :duration_ms
)
# Δ flags ⊆ [:escaped_transaction, :time_unfrozen, :truncated_value, :seq_present,
#            :import_mutated, :redaction_read, :callbacks_ran_on_import]

VerifyResult = Data.define(:config, :status, :diagnosis, :retried)
# Δ config: :isolated | :hostile | :neighbored ; status: :green | :remedied | :failed | :skipped

PinScore = Data.define(:case_id, :aspect, :mutations_killed, :verdict)
# aspect: :return | :error | :jobs | :mail | :sql
# verdict: :strong | :weak | :worthless
```

**File formats (JSON boundary):**

`cases.json` — `{ "plan_id":, "serializer": 3, "setup_plan": [...], "fk_map": {...}, "isolation":, "env_fingerprint": {...}, "cases": [{id, ctor_args, ctor_kwargs, args, kwargs}] }`

Δ **Case argument encoding is normative:** every value in `ctor_args`/`ctor_kwargs`/`args`/`kwargs` uses serializer-v3 tags, and the probe resolves `{t:"ref"}` against its identity map immediately before invocation. Hash keys arrive as JSON strings; the probe symbolizes `kwargs` keys and forwards them through **one** version-guarded shim in the template — the empty-keyword-splat behavior differs before Ruby 2.7 and must not be open-coded per call site. (v0.2 left this boundary undeclared; it is the second-most-crossed boundary in the system.)

`observations.json` — `{ "pinspec_probe_version": 3, "serializer": 3, "plan_id":, "env": {...}, "observations": [...] }`

**Tagged encoding v3:** `{"t":"int"}` `{"t":"str"}` `{"t":"nil"}` `{"t":"sym"}` `{"t":"decimal"}` `{"t":"date"}` `{"t":"bin","v":"<base64>","enc":}` `{"t":"nan"}` `{"t":"inf","sign":}` `{"t":"cycle","class":}` `{"t":"relation","total":,"first":[…]}` `{"t":"ref","v":"invoice_1"}`, plus:

Δ `{"t":"seq"}` — an autoincrement-shaped integer that cannot be resolved to a plan ref (the record's own PK, a PK of another record the target created, elements of an unresolvable `*_ids` array). Asserts *"an Integer is present here"* and compares equal to any Integer. Preserves shape, pins nothing unportable. Occurrences are counted in the report as a coverage caveat and excluded from the strong-aspect numerator (§14).

**Removed:** v0.2's implicit rule that FK rewriting applied only to plan-created and imported instances (§9).

## 7. Module micro-specs

Format: purpose → interface → behavior → acceptance → effort/risk. Δ marks v0.3 changes.

---

### M-01 TargetParser (`analyzer/target_parser.rb`)

**Purpose:** resolve `FILE#METHOD` → `TargetProfile` via Prism. No target-app code loaded.

**Interface:** `TargetParser.parse(file_path, method_name) → TargetProfile | raise TargetNotFound, AmbiguousTarget, BlockRequired, UnresolvableSetup(:opaque_constructor)`

**Behavior:**
- As v0.2: locate class/module, instance vs class method, param kinds + default sources, heuristic type hints (never trusted without fallback), exact `source_range`, delegation/`method_missing` redirect in `TargetNotFound`, `BlockRequired` on `&block`/`yield`, `**rest` accepted with a report note.
- Δ **Constructor resolution (row 29)** — the invocation surface v0.2 omitted. Determine `construction_kind` and `initializer_params`:

  | Shape | Detection | Invocation |
  |---|---|---|
  | `:new` | `def initialize` in class body | `Klass.new(*ctor_args, **ctor_kwargs).method` |
  | `:class_method` | target is `def self.x` / `class << self` | `Klass.method(...)`, `initializer_params: []` |
  | `:interactor` | `include Interactor` + `def call` | `Klass.call(context_hash)`; ctor params = declared `delegate`d context keys |
  | `:dry_initializer` | `extend Dry::Initializer` / `option`/`param` calls | `Klass.new(**options)` |
  | `:struct` | superclass `Struct.new(...)` / `Data.define(...)` | positional members as ctor params |
  | `:model_instance` | class `< ApplicationRecord` | subject is a plan record (v0.2 behavior) |

  No `initialize` and not a class method → `:new` with zero args. `initialize` calling `super` with arguments, or assigning from a DI container/`Rails.application.config`, and not statically resolvable one level up → `UnresolvableSetup(:opaque_constructor)` naming the superclass or the constant. **Refusing is fine; being silent is what v0.2 did.**
- Δ **Clock-site detection (row 35).** Collect `Time.now`, `Time.new`, `Date.today`, `DateTime.now` call sites into `clock_sites`. These read the **process** zone, which `:set_zone` does not govern, and neither StabilityFilter (same machine) nor an isolated M-13 (same machine) can see the drift — it surfaces on the client's CI. Feeds M-09's guard and M-13's `:hostile` config.
- Δ `referenced_constants` becomes load-bearing: it is the feed for Flipper detection (M-05.9), attachment detection (M-05.11), and clock sites. v0.2 collected it and never used it.

**Acceptance:** v0.2 checklist, plus:
- [ ] All six `construction_kind` shapes resolved on fixture targets; `initializer_params` correct for each
- [ ] `initialize` calling `super(dep)` from an unresolvable superclass → `UnresolvableSetup(:opaque_constructor)`, exit 5
- [ ] Target using `Time.now` → one `clock_sites` entry with the right line
- [ ] Delegated method → error names `to:` target file; `yield` → `BlockRequired`, exit 4 (distinct from 2)

**Effort: 14h (+6). Risk: low-medium** — constructor shapes are enumerable but the tail (custom DSLs) is long; refusal keeps the tail cheap.

---

### M-02 SchemaReader (`analyzer/schema_reader.rb`)

**Purpose:** `db/schema.rb` → `SchemaGraph`. Static parse, no DB connection.

**Behavior:**
- As v0.2: `create_table` blocks, all column kinds, references/`belongs_to` expansion (polymorphic → `_id` + `_type`), unique + composite indexes, `add_foreign_key`, unknown-DSL resilience via `skipped_statements`, `structure.sql` → `SchemaFormatUnsupported` (exit 6) with the `db:schema:dump` workaround.
- Δ **Emit `fk_map`** — `{"table.column" => "target_table"}` from references/`belongs_to` expansion ∪ `add_foreign_key` ∪ a marked heuristic tier (`*_id` whose stem pluralizes to a known table). The probe needs this to distinguish a foreign key from a quantity; v0.2's `cases.json` carried no such map, which is why FK→ref rewriting could not have worked even where §9 required it.
- Δ `skipped_statements` entries gain `relevant:` — true when the skipped statement's table appears in the plan. A `create_view` on a table nothing touches is noise; the same view on a planned table is a real hazard. Unconditional surfacing is how a warning becomes ignored.

**Acceptance:** v0.2 checklist, plus:
- [ ] `fk_map` covers references, `belongs_to`, `add_foreign_key`, and the heuristic tier, with the heuristic entries flagged
- [ ] Polymorphic association contributes no `fk_map` entry (type column makes the target dynamic); documented, and M-07 emits `{t:"seq"}` for its id

**Effort: 8h (+1). Risk: low.**

---

### M-03 FactoryIndex (`analyzer/factory_registry.rb`)

Unchanged from v0.2: static Prism parse of `spec/factories/**` and `test/factories/**`, structure only, never executed; `factory_girl` support via Gemfile.lock detection → `legacy_dsl: true` → emitted specs call `FactoryGirl.create`.

**Effort: 6h. Risk: low.**

---

### M-04 AppProfile (`analyzer/app_profile.rb`)

**Purpose:** one-pass detection of everything SetupPlan, probe, SpecWriter, and Verifier need. The hazard scanner.

**Behavior:** as v0.2 (Gemfile.lock truth for devise/pundit/cancancan/acts_as_tenant/ros-apartment/paranoia/discard/factory_bot/factory_girl/rspec-rails/webmock/vcr/insta/approvals/paper_trail/flipper/carrierwave/paperclip/spring/database_cleaner; `database.yml` + `connects_to` → `multi_db`; attachments; `config/application.rb` → locale + zone; model scan for `acts_as_tenant`, `default_scope`, `after_commit` family, `has_paper_trail`, attachment macros), plus:

- Δ **`transactional_fixtures`** — `use_transactional_fixtures` / `use_transactional_tests` from `rails_helper.rb`/`spec_helper.rb`. Together with `db_cleaner` this decides `SetupPlan#isolation`. v0.2 detected `db_cleaner` and used it only as an M-13 diagnosis input, which is how the isolation asymmetry survived review.
- Δ **`queue_adapter_in_tests`** — grep `rails_helper`/`config/environments/test.rb` for `queue_adapter`. `:inline` or a real adapter means the app's own config will defeat job pins unless the emitted spec forces `:test` (M-09); feeds M-13's `:adapter_mismatch`.
- Δ **`rails_floor_ok`** — Rails ≥ 6.0. False → `UnsupportedRailsVersion` (exit 10) naming the version and the three APIs that are missing (§0.1). Fail at `analyze`, not at the first `insert_all`.

**Acceptance:** v0.2 checklist, plus:
- [ ] `rails61_legacy` (DatabaseCleaner truncation, `use_transactional_fixtures = false`, factory_girl) profiles all three correctly
- [ ] A fixture `rails_helper` setting `queue_adapter = :inline` → `queue_adapter_in_tests: :inline` and an analyze warning
- [ ] A Rails 5.2 fixture stanza → exit 10 with the API list

**Effort: 10h (+2). Risk: low.** `pinspec analyze` (M-01..M-04) remains the standalone weekend-1 artifact and is now a genuine pre-engagement hazard report.

---

### M-05 ContextBuilder + DependencyResolver (`setup/`)

**Purpose:** THE long pole. TargetProfile + AppProfile + hydrated samples → `SetupPlan`.

**Interface:** `ContextBuilder.build(target:, profile:, imports: [], generation: 1) → SetupPlan | raise UnresolvableSetup(reason:)`

**Behavior rules (ordered; Δ marked):**
1. Root records: params with model hints, Δ **plus initializer params with model hints**, plus the subject record for `:model_instance` targets.
2. Creation strategy per model: factory → `:create_record`; else schema-driven minimal `Model.create!`.
3. `belongs_to` transitive walk (schema FKs ∪ factory assocs), topo-sort; cycles broken at `optional: true`, else `UnresolvableSetup(:association_cycle)`.
4. Uniqueness → deterministic `-p{generation}-{counter}` uniquifier. Δ The remedy for a collision must also **re-salt imported unique columns** (M-06's redaction salt), because a seed-data collision on an *imported* email is unreachable by a created-record counter and would loop M-13 to `:failed`.
5. Tenancy: `acts_as_tenant` wrap; apartment → `UnresolvableSetup(:apartment)`.
6. Auth: devise stub / `Current` attributes / pundit note.
7. Always: `:freeze_time`, `:seed_random`, `:set_locale`, `:set_zone` from profile defaults.
8. Polymorphic: sampled-majority type, else first concrete model; recorded.
9. Flipper: explicit `:set_flag {flag:, enabled: false}` per flag referenced in the target source; states listed in the report.
10. PaperTrail: `:set_whodunnit` bound to the auth user.
11. Attachments: target's model has `has_one_attached`/`mount_uploader` **and** the target references the attachment → `UnresolvableSetup(:attachment)` naming the attribute. Blob synthesis is P1.
12. Δ **`:construct_subject`** — emitted for every non-`:model_instance`, non-`:class_method` target, after all record steps, before invocation. Payload carries `kind` so both hosts build the subject the same way (`Klass.new(...)` vs `Klass.call(ctx)` vs `Klass.new(**options)`).
13. Δ **`:isolation`** — `:truncation` when `transactional_fixtures == false` or `db_cleaner == :truncation`; else `:transaction`. Overridable with `--isolation`. This one field is what makes row 17's consistency claim true instead of aspirational: whichever regime is chosen, probe and emitted spec are both in it, and the report says which and what that means for `after_commit`.
14. Δ **`:env_fingerprint`** — `{tz: ENV["TZ"] || "UTC", locale:, zone:, rails:, ruby:, serializer: 3}`, stamped into probe and spec. Feeds M-09's TZ guard and M-13's `:hostile` config.
15. Δ **Replan is quarantine-first.** A `setup_error` on one case **drops that case** with a report line; the plan and every good observation stand. Replan the whole plan (new `plan_id`, `generation + 1`, cap 3) only when *all* cases setup-error, or when the error has a global remedy (uniqueness → bump generation namespace + re-salt imports; validation failure on `:create_record` → next factory trait in declared order). v0.2 tied per-case failures to whole-plan regeneration, so one pathological boundary case could burn three probe boots and invalidate good observations.

**Acceptance:** matrix rows 1–10, 18–20, 25, 28 (from v0.2) **+ 29, 31, 37** now gate M2. Plan remains pure data — never touches the app process or a DB.

**Effort: 34–42h (+6). Risk: HIGH, unchanged rationale.** Matrix-driven, one row per commit, stop-the-line on regressions.

---

### M-06 InputSampler + BoundaryGen + Hydrator + Redactor (`inputs/`)

**Purpose:** produce `InputCorpus` (ctor ∪ method inputs) + import clusters.

**Interface:** `Corpus.build(target:, profile:, db: SampleDb, max_cases: 12) → {corpus: InputCorpus, imports: [ImportCluster]}`

**Behavior:**
- Δ **Sample DB default: `development` if it resolves and the target's tables have rows, else `test`** — and the choice, plus the row count found, is printed and reported. v0.2 defaulted to the test DB, which is empty, so the default configuration silently disabled import clusters, sampled cases, and stratified sampling while M5's DoD required an import cluster. Plan-time hydration is exactly what makes cross-env sampling safe: the read is read-only, in the CLI process, before the probe boots. Zero rows found → a loud line: *"no sampled rows; corpus is boundary-only, coverage will be thin."*
- **Plan-time hydration.** For model-typed params (Δ *and constructor params*): sample rows (newest, oldest, 3 seeded-random), then fetch the transitive `belongs_to` closure, depth ≤ 3, ≤ 20 rows per cluster, from the read-only sample connection. Emit `ImportCluster` — attribute hashes with PKs dropped, intra-cluster FKs rewritten to refs, cross-cluster FKs → nullable ? nulled : cluster extended within caps : row discarded with a report note. The probe never opens the sample connection.
- Δ **Redaction, default ON, domain- and length-preserving.** Built-in attribute list (email, phone, ssn, dob, first_name, last_name, full_name, address\*, ip_address, token, api_key) ∪ `.pinspec.yml redact_attributes`. Rewrites preserve **domain and length**, not just shape:
  - `rehan.munir@acme.co` → `person1.aaaaa@acme.co` (same length, same domain — kills domain routing, allowlist, and `split("@").last` divergence)
  - phone → same-format, same-length digits · names → same-length `Person{n}` padded · tokens → same-length random hex
  v0.2's `user1@example.test` changed both the domain and the length, which is a behavior change in every target that routes on domain or validates length.
- Δ **Read detection (row 34).** Prism-scan the target for each redacted attribute name (symbol, string, `record.email`, `[:email]`). A hit → `:redaction_read` flag on every affected observation **and** a warning at the top of the emitted spec naming the attribute and line — not a report footnote. Honest limit, stated in the report: transitive callees are invisible to a single-file scan, so absence of a hit is not proof of absence.
- Δ **Provenance is hashed by default** — `source: "sample:invoices:<sha1_8>"`. A committed spec file that maps fixtures to production row ids is its own governance conversation, and the audit-deliverable buyer is the buyer who raises it. `.pinspec.yml provenance: :raw` opts back in.
- **Status-stratified sampling:** target's model has an `enum` or a string `status`/`state` column → one sampled row per distinct value (cap 6), `origin: :stratified`.
- Boundary scalars: ints/strings/decimals/dates/bools/omitted-optional. Δ **OFAT spans `ctor_params ∪ method_params`** under the same `--cases` cap, all-defaults-first still first, then dedup. Constructor params typically outnumber method params for `#call` targets, so the cap allocation is: 1 all-defaults case, then round-robin one variation per param across both sets until the cap is hit — so a 12-case budget never spends all 12 on the constructor.
- Sample connection read-only + prod-URL hard-confirm: unchanged.

**Acceptance:** v0.2 checklist, plus:
- [ ] Redaction preserves domain and length; a target doing `email.split("@").last` observes the real domain
- [ ] Read detection: fixture target regexing on `email` → `:redaction_read` flag + spec-header warning naming the line
- [ ] Sample-DB default picks `development` when populated and says so; empty → the loud boundary-only line
- [ ] Ctor ∪ method OFAT: a target with 3 ctor params and 1 method param gets coverage of both under `--cases 6`

**Effort: 18h (+4). Risk: medium.**

---

### M-07 ProbeGenerator + Sandbox (`runner/`)

**Purpose:** generate the stdlib-only probe; execute inside the target app; collect observations.

**Probe contract (generated `tmp/pinspec/probe.rb`, Ruby 2.6-safe, requires `json` only):**

- Env guard: `Rails.env.test?` or `PINSPEC_UNSAFE=1` post-confirm.
- **Process setup, once:** `ActiveJob::Base.queue_adapter = :test`; `ActionMailer::Base.delivery_method = :test`; `perform_deliveries = true`. Callbacks firing *during* SetupPlan (the `after_create :sync_to_stripe` legacy special) enqueue into test sinks instead of hitting Stripe.
- Δ **Identity map.** `{[table, pk] => ref}`, populated by `:create_record` and `:import_record`. Consumed by the serializer for FK→ref rewriting on **every** AR instance (§9), not just plan-created ones.
- **Per case:**
  1. Δ Δ enter isolation per `SetupPlan#isolation` — `:transaction` → `transaction(requires_new: true)`; `:truncation` → no wrapper, record touched tables for post-case truncation.
  2. Execute steps, including Δ `:import_record` (below) and Δ `:construct_subject`.
  3. **Clear side-effect sinks** — after setup, before target — so setup noise is never attributed to the target.
  4. Subscribe `sql.active_record` (§10 filters applied at capture).
  5. Invoke target under `begin/rescue`. Δ kwargs symbolized and forwarded through the single version-guarded shim (§6).
  6. Capture `enqueued_jobs` + `mail_deliveries` from sinks; serialize per §9.
  7. Exit isolation — rollback, or truncate the recorded tables.
- Δ **`:import_record` uses `insert_all`** (skips validations **and** callbacks), then refetches by returned PK to bind the ref, then **diffs the refetched attributes against the requested ones**. Any difference → `:import_mutated` flag + report note. Fallback to `save!(validate: false)` only when `insert_all` is unavailable, and then set `:callbacks_ran_on_import`. v0.2's `create!` could not import rows that fail today's validations — the rows worth importing — and its callbacks silently rewrote imported attributes with nothing detecting it.
- **Between cases:** `Rails.cache.clear`; `ActiveSupport::CurrentAttributes.reset_all`; sinks cleared. `Thread.current` residue is not safely clearable — mitigated by two boots, named as residual risk.
- **Setup failures are data:** any step raising → `status: :setup_error` with the step index; the probe continues. M-05.15 quarantines the case.
- Δ **Run 2 is a second boot by default.** Order is shuffled (seeded) within *both* boots. `--fast` runs run 2 in-process instead, and its report line says what that cannot detect: an input-keyed memo (`@rate ||= compute(customer)`) filled by run 1's first case is reused by every later case *and all of run 2*, so both runs agree while the pinned value is an artifact of which case ran first. v0.2 made in-process shuffle the default and asserted an acceptance test ("memoization fixture diverges") that only holds when the memo's *presence* is input-dependent.
- **Rollback-breach detection (row 22):** per-case fingerprints scanned for `COMMIT`, DDL, `pg_advisory_lock` → `:escaped_transaction`, excluded from pins, loud in report. Under `:truncation` isolation the scan is limited to advisory locks and DDL.
- Sandbox env always exports `DISABLE_SPRING=1` and Δ `TZ=UTC`. Time freeze via one template-constant `travel_to` call site with `with_usec` behavior pinned (§4c clock axis). Global timeout + heartbeat attribution; no per-case `Timeout` (thread-kill mid-transaction corrupts the connection pool). `ruby -c` 2.6 syntax guard in CI.

**Acceptance:** v0.2 checklist, plus:
- [ ] Target returning a newly created record with a FK to a plan record → FK serialized as `{t:"ref"}`, own PK as `{t:"seq"}`, and **run 1 == run 2** across two boots (this is the row-30 regression test)
- [ ] Legacy fixture row violating a current validation imports successfully via `insert_all`
- [ ] Import whose model has a recomputing `before_save`: `insert_all` path shows no `:import_mutated`; forced `save!(validate: false)` path shows it
- [ ] `:truncation` isolation: `after_commit` fires, is captured, and the tables are clean afterward (row-count CI proof across all configured connections)
- [ ] First-touch `SCHEMA` queries do not make case 1 diverge from run 2 (row 32)
- [ ] `--fast` emits the memoization caveat line

**Effort: 25h (+7). Risk: medium-high.** Feature-detect, never version-sniff; 7.1 + 6.1 CI matrix.

---

### M-08 StabilityFilter (`emit/stability_filter.rb`)

**Behavior:**
- Join run1/run2 by `case_id`. Δ **Compare a declared field set** — `status`, `return_value`, `error`, `enqueued_jobs`, `mail_deliveries`, `db_delta`, and `sql_fingerprints` **only when SQL pins were requested**. `duration_ms` never participates. v0.2 said "deep-compare," which included `duration_ms` (never equal) and SQL fingerprints (the most fragile field in the record, and opt-in for pinning), so the two least meaningful fields decided the fate of every pin.
- Δ Cause taxonomy: `:time`, `:random`, `:float_noise`, `:order_dependent`, `:escaped_transaction`, **`:identity_churn`** (an autoincrement-shaped integer differing between runs — the correct diagnosis for what v0.2 reported as `:external_io`), `:external_io` (fallback + WebMock suggestion).
- A ≤10-line diff excerpt per unstable case. "Unstable" without the diff is an accusation; with it it's a lead.
- Δ All cases unstable or quarantined → exit 8 `NothingStableToPin`, with the cause histogram. Never a silent empty spec.

**Acceptance:** v0.2 pair, plus:
- [ ] Class-ivar memoization fixture → `:order_dependent` with diff excerpt (two-boot path)
- [ ] A fixture that deliberately returns a raw PK with no ref → `:identity_churn`, not `:external_io`

**Effort: 9h (+2). Risk: low.**

---

### M-09 SpecWriter + SnapshotAdapter (`emit/`)

**Behavior:**
- Output path, header provenance (incl. `plan_id`, `serializer: 3`, `env_fingerprint`): as v0.2.
- Δ **Never-touch-existing-specs gains a self-carve-out** (§12.6). pinspec may overwrite a file it generated, identified by its header provenance block; it refuses on any file lacking that header, and refuses on a file whose header is present but whose body hash doesn't match what pinspec last wrote (i.e. hand-edited) unless `--force`. As written in v0.2 the rule either forbade re-pinning entirely or silently clobbered hand edits — and users edit pinned specs.
- Δ **Generated serializer helper** `spec/characterization/support/pinspec_serializer.rb` — self-contained, zero-dep, generated from `templates/serializer.rb.erb` (the same template as the probe encoder), version-stamped, regenerated never hand-edited. Δ **Signature:** `PinspecSerializer.normalize(value, refs:, fk_map:)`. The spec host's job is the *inverse* of the probe's — turn a live AR instance into `{t:"ref", v:"invoice_1"}` — which needs the spec's own ref table; v0.2's one-argument `normalize(result)` could not do it. `fk_map` is inlined as a frozen constant. A ref appearing in a stored snapshot with no entry in `refs` raises `PinspecInternalError` (exit 12), not a failed expectation — a missing ref is our bug and must not look like a behavior change.
- Δ **Emitted setup builds the ref table:** `let(:pinspec_refs) { {"invoice_1" => invoice_1, "customer_1" => customer_1, …} }`, populated in plan-step order.
- Δ **Isolation wrapper** matching `SetupPlan#isolation`, which **overrides** the suite's own strategy:
  ```ruby
  around do |ex|                     # :transaction
    ActiveRecord::Base.transaction(requires_new: true) { ex.run; raise ActiveRecord::Rollback }
  end
  ```
  Under `:truncation`, no wrapper plus a documented note that the example mutates the test DB. This is the fix for the DatabaseCleaner divergence: v0.2 emitted no wrapper and inherited whatever the app did.
- Δ **Sink contract, symmetric with the probe:**
  - `around { |ex| old = ActiveJob::Base.queue_adapter; ActiveJob::Base.queue_adapter = :test; ex.run; ActiveJob::Base.queue_adapter = old }` — because an app whose `rails_helper` sets `:inline` (detected as `queue_adapter_in_tests`) executes jobs instead of queueing them and zeroes every job pin.
  - `before { ActionMailer::Base.deliveries.clear }` — deliveries are not cleared per example unless the app or a helper does it, so example 2's mail count would include example 1's.
  - **Block-form matchers, always:** `expect { subject }.to have_enqueued_job(SyncJob).with(...)`. In rspec-rails `have_enqueued_job` is a block matcher; the non-block form is `have_been_enqueued` and it counts setup enqueues. Block form is also the spec host's only equivalent of the probe's clear-after-setup point — it is a correctness requirement, not a style preference. Where the matchers are unavailable, an inline assertion against the test adapter's queue, serialized through the same helper.
- Δ **TZ guard** when `clock_sites` is non-empty: a `before(:all)` that fails with a named message if `ENV["TZ"]` differs from `env_fingerprint[:tz]`, plus a header warning naming each `Time.now` line. The one contract axis that can only be guarded, not enforced (§4c).
- SetupPlan → readable `let!`/`before` blocks; Δ `:import_record` renders as an explicit `Model.insert_all` + refetch with a `# imported from sample:invoices:3f9a1c2b (redacted: email, phone)` comment — auditability over magic. Δ `:construct_subject` renders as the `subject` block.
- Backends (`:inline`/`:insta`/`:approvals`) via adapter; raised-error pins; opt-in SQL pins; `legacy_dsl` → `FactoryGirl`: unchanged.

**Acceptance:** v0.2 checklist, plus:
- [ ] Emitted spec contains zero literal DB ids (grep-able CI assertion) **and** ≥1 return-or-error pin and ≥1 side-effect pin — the positive half v0.2's DoD lacked
- [ ] Job-enqueue pin goes red when the fixture service's `perform_later` line is commented out
- [ ] Job pin stays green in an app whose `rails_helper` sets `queue_adapter = :inline`
- [ ] Two pinned examples in one file: the second's mail count excludes the first's deliveries
- [ ] Under `:truncation` profile, the emitted spec still wraps in a transaction when `isolation == :transaction`, and `after_commit` stays suppressed
- [ ] Re-pinning the same target overwrites pinspec's own output; a hand-edited pin file is refused without `--force`

**Effort: 20h (+6). Risk: medium.**

---

### M-10 Namer — the only LLM touchpoint (`emit/namer.rb`)

Unchanged: names and grouping only, JSON-schema-validated, deterministic fallback, `--no-llm`, expected values structurally unreachable. `--annotate` (LLM flags probable bugs among the pins, prose only) remains P1.

**Effort: 5h. Risk: low.**

---

### M-11 MutationAdapter + PinScorer (`validate/`)

Unchanged backend stance (mutineer default for licensing, mutant opt-in, adapter-isolated, `--validate` opt-in). Scores per **aspect** — return/error and side-effect pins graded independently, so a mutation deleting a `perform_later` is killed by the job pin even when the return pin sleeps through it.

- Δ **Spike at M1, not M5.** M5's DoD depends on the default backend booting a real Rails app, targeting a `source_range`, and running a single spec file. That is an unvalidated third-party dependency gating the final milestone. A 2h spike against `rails71_basic` in weekend 1 tells you whether to swap the default — cheap insurance against learning it in weekend 11.
- Δ **Strong-aspect numerator excludes** pins bearing `{t:"seq"}` or `:truncated_value`. Those assert less than they appear to, and §14's metric must not be inflatable by them.

**Acceptance:** v0.2 checklist, plus: vacuous-return + meaningful-job fixture → return pin `:worthless`, job pin `:strong`.

**Effort: 12h (+2, incl. the M1 spike). Risk: medium.**

---

### M-12 Report (`report/summary.rb`)

Sections from v0.2 (redactions applied · flag states pinned · `after_commit` suppression note · escaped-transaction incidents · unstable cases with diff excerpts · verification outcome · import provenance), plus Δ:

- **Isolation regime** in force and what it means for `after_commit` (the §12.7 text, verbatim).
- **Verification matrix** — three rows (isolated / hostile / neighbored), each with status and diagnosis.
- **Coverage caveats** — `{t:"seq"}` count, truncated-value count, depth-cap hits, relation caps, quarantined cases with their setup errors.
- **`:redaction_read` warnings** with attribute and line, and the single-file-scan limitation stated.
- **Clock sites** and whether the TZ guard is active.
- **Sample-DB provenance** — which DB, how many rows found, and the boundary-only warning when zero.
- **Constructor shape** resolved, and `:opaque_constructor` refusals.

Remains the client-facing audit artifact.

**Effort: 8h (+2). Risk: low.**

---

### M-13 Verifier (`verify/verifier.rb`)

**Purpose:** the emitted spec must survive the app's real `rails_helper` world **and be portable off this machine**. v0.2 ran the spec once, in isolation, on the capture machine, and called green "zero manual edits."

**Interface:** `Verifier.verify(app_root:, spec_path:, level: :full) → [VerifyResult]` (one per config)

Δ **Three configurations.** Same command, different environment — the cheapest high-value change in this revision:

| Config | How | Catches |
|---|---|---|
| `:isolated` | `bundle exec rspec <file> --format json` (v0.2 behavior) | rails_helper variance, VCR/WebMock, seed collisions |
| `:hostile` | `TZ=Etc/GMT+8 LANG=C LC_ALL=C`, after `db:test:prepare` (fresh sequences), different `--seed` | TZ dependence, sequence dependence, collation ordering, locale drift |
| `:neighbored` | `rspec <file> <file> <one sibling spec from the app's suite>` | accumulating `deliveries`, leaked globals, `Flipper`/`Current` residue, "passes alone, fails in suite" |

`--verify-level isolated` runs only the first; `--skip-verify` runs none. `pin` exits 0 only when every requested config is `:green` or `:remedied`.

**Diagnosis table (first match wins):**

| Symptom | Diagnosis | Remedy |
|---|---|---|
| `WebMock::NetConnectNotAllowedError` / `VCR::Errors` | `:unpinnable_http` | none; report names the request line |
| `RecordNotUnique` / uniqueness validation text | `:seed_collision` | bump generation namespace **+ re-salt imported unique columns** (M-05.4), re-emit, retry once |
| Δ extra jobs/mail + profile says `after_commit` present | `:isolation_mismatch` | flip `SetupPlan#isolation` once, re-emit, retry |
| Δ zero jobs where jobs were pinned, and `queue_adapter_in_tests != :test` | `:adapter_mismatch` | force the adapter in the emitted `around`, re-emit, retry once |
| Δ `:hostile` fails where `:isolated` passed, and `clock_sites` non-empty | `:tz_dependent` | none; report names the `Time.now` lines |
| Δ `:hostile` fails after `db:test:prepare` with id-shaped diffs | `:sequence_dependent` | none — it means a raw id escaped `{t:"seq"}`; that's `PinspecInternalError` territory, dump verbosely |
| Δ `:neighbored` fails where `:isolated` passed | `:suite_contaminated` | none; report names the sibling spec |
| Failure diff confined to id/timestamp-shaped values | `PinspecInternalError` | none; verbose dump to **our** tracker — our bug, never the user's |
| `DatabaseCleaner` strategy error | `:db_cleaner_strategy` | documented note |
| `LoadError`/`NameError` on helper load | `:rails_helper_variance` | report with backtrace head |

**At most one automated remedy-retry per config.** Never edits anything outside `spec/characterization/`.

**Acceptance:**
- [ ] `before(:suite)` seed colliding on a unique column → `:remedied`; and the same collision on an *imported* column also `:remedied` (the v0.2 remedy could not reach this)
- [ ] WebMock strict + HTTP-calling target → `:failed`, `:unpinnable_http`, request line named
- [ ] `rails61_legacy` (truncation, `use_transactional_fixtures = false`) → `:green` in all three configs
- [ ] A deliberately TZ-dependent fixture target → `:isolated` green, `:hostile` `:tz_dependent`
- [ ] Two-examples-one-file mail fixture → `:neighbored` green (proves the deliveries clear)
- [ ] Full matrix adds < 90s on fixture apps

**Effort: 14h (+4). Risk: medium** — rails_helper wildness is unbounded; the taxonomy stays deliberately small with an honest `:failed` fallthrough.

---

### M-14 HostEquivalence — NEW (`spec/equivalence/`)

**Purpose:** make "the two hosts agree" a build-breaking test instead of a design intention. This is pinspec's own CI harness, not a runtime module — and it is the mechanism that would have caught every Tier-1 finding in this revision.

**Interface:** an RSpec suite in pinspec's repo. For each contract axis (§4c) and each fixture app: build a plan, run the probe, emit the spec, run the spec, and assert the two observations are **identical** under the axis's own perturbation.

| Axis | Perturbation | Assertion |
|---|---|---|
| Encoding | target returns each §9 value kind (incl. binary, NaN, cycle, relation, created-record-with-FK) | probe encoding == helper normalization, byte-for-byte |
| Isolation | fixture app configured `:transaction` and `:truncation` | `after_commit`-driven job counts equal in both hosts, per regime |
| Sinks | `after_create` enqueue in setup + `perform_later` in target; app `rails_helper` sets `:inline` | both hosts attribute exactly the target's enqueue |
| Clock | target returns `Time.current`, a duration, and `Time.now.usec` | equal in both hosts, incl. sub-second handling |
| Locale | app default `:en`, target returns a translated string; suite sets `:fr` | both hosts observe the plan's locale |
| Zone | app zone `America/New_York`, target uses `Time.zone.now` and `Time.now` | zone-aware call equal; `Time.now` call flagged in both hosts, not silently equal |

**Acceptance:**
- [ ] All six axes green on `rails71_basic` and `rails71_full`; isolation axis green on `rails61_legacy`
- [ ] Deliberately breaking the helper template (e.g. removing FK→ref rewriting) fails the encoding axis — the harness must be able to fail

**Effort: 8h. Risk: low.** Gate: M4. Highest leverage-per-hour in the plan.

## 8. Repository layout

```
pinspec/
  exe/pinspec
  lib/pinspec/
    cli.rb  version.rb  errors.rb  orchestrator.rb      # quarantine + replan + verify-matrix loop
    analyzer/   target_parser.rb  schema_reader.rb  factory_registry.rb  app_profile.rb
    setup/      context_builder.rb  dependency_resolver.rb
    inputs/     sampler.rb  boundary.rb  corpus.rb  hydrator.rb  redactor.rb
    runner/     probe_generator.rb  sandbox.rb  capture.rb  identity_map.rb
    emit/       stability_filter.rb  serializer_rules.rb  spec_writer.rb
                snapshot_adapters/{inline,insta,approvals}.rb  namer.rb
    verify/     verifier.rb  diagnoses.rb
    validate/   mutation_adapter.rb  pin_scorer.rb
    report/     summary.rb
  templates/    probe.rb.erb  spec.rb.erb  serializer.rb.erb     # ONE serializer template, two hosts
  spec/         unit specs per module
    equivalence/                                                 # M-14
  test_apps/    rails71_basic/  rails71_full/  rails61_legacy/
                # rails71_full: paper_trail, flipper, an after_commit that enqueues,
                #   an enum status column, a seeded before(:suite) unique-collision trap,
                #   a target returning a newly created record with a FK (row 30),
                #   a TZ-dependent target (row 35), a redaction-read target (row 34)
                # rails61_legacy: factory_girl, DatabaseCleaner :truncation,
                #   use_transactional_fixtures = false (row 31), a legacy row that
                #   violates a current validation (row 33)
                # Gemfile.locks committed; CI caches by lock hash
  .github/workflows/ci.yml   # {cli 3.2/3.3} × {fixture apps} + probe `ruby -c` 2.6 guard
                             # + M-14 equivalence suite + zero-literal-id grep
```

Gem deps unchanged (CLI only): `prism`, `thor`, `zeitwerk`, `anthropic` (soft).

## 9. Serialization rules v3 (snapshot stability contract)

One template → probe encoder + generated spec helper (§4c). Version `serializer: 3`; a bump regenerates everything and never reinterprets stored snapshots.

Δ **The FK-rewriting rule is a property of the *value*, not of the row it appears in.** For any AR instance, regardless of how it came to exist: drop `id`, drop auto-volatile columns, and for every remaining attribute whose `"table.column"` is in `fk_map` and whose value is in the probe's identity map → `{t:"ref"}`. This is the change that makes "returns the record it created" pinnable.

| Value | Serialized as | Rule |
|---|---|---|
| AR instance, plan-created or imported | `{class:, ref:, attributes: {…}}` | identity = ref; `id` dropped; FK attrs → refs |
| Δ AR instance, target-created or otherwise | `{class:, attributes: {…}}` | `id` dropped; **FK attrs → refs (same rule)**; unresolvable id-shaped attrs → `{t:"seq"}` |
| Δ id-shaped integer with no resolvable ref | `{t:"seq"}` | own PK, another target-created row's PK, `*_ids` elements; compares equal to any Integer |
| AR::Relation / large array | `{t:"relation", total:, first:[…≤ max_collection]}` | relation's own order, else `id`-ordered before cap; `total` is plan-dependent (§16 note) |
| BigDecimal | `"19.99"` string | never float |
| Float | round 10 places | `NaN` → `{t:"nan"}`; `±Infinity` → `{t:"inf",sign:}` |
| Time/DateTime/Date | ISO8601 UTC | frozen clock (one template call site), pinned zone |
| String, binary encoding | `{t:"bin", v: base64, enc:}` | JSON raises on raw `ASCII-8BIT` |
| Symbol / Hash / Struct-Data-PORO | sym tag; insertion order; depth-cap 4 | cycle via seen-set → `{t:"cycle", class:}`; depth-cap hit → `:truncated_value` |
| Proc/IO/socket | `{class:, unpinnable: true}` | class-only pin |
| Exception (returned) | `{class:, message:}` | |

Auto-volatile: `created_at`, `updated_at`, any column whose schema default is a DB function (`gen_random_uuid()`, `now()`, `uuid_generate_v4()`), ∪ `.pinspec.yml volatile_attributes`.

## 10. SQL fingerprinting v3

As v0.2 (literals → `?`, binds, `IN (?+)`, whitespace, savepoints dropped, `×N` collapse, ignore-tables list: `versions`, `active_storage_*`, `ar_internal_metadata`, `schema_migrations` ∪ `.pinspec.yml ignore_tables`), plus Δ **notification-level filters applied at capture:**

- `payload[:name] == "SCHEMA"` — Rails' own column/type introspection, emitted **once per model class per process**. Without this filter the first case touching each model diverges from run 2 (which shares the process in `--fast`) or from every other case (in two-boot mode). This alone would have made a large fraction of every corpus spuriously unstable.
- `payload[:name] == "TRANSACTION"` — `BEGIN`/`COMMIT`/`SAVEPOINT` in current Rails.
- `payload[:cached]` truthy — query-cache hits, which depend on executor wrapping and differ between `rails runner` and an RSpec example.

Breach patterns (`COMMIT`, DDL, advisory locks) are detected **before** the `TRANSACTION` filter drops them, per §7 M-07.

### 10.1 `db_delta` honesty (new)

`db_delta` is derived from the fingerprint stream, not from row counts — under `:transaction` isolation there is nothing left to count after rollback. It therefore counts **attempted** writes, including writes inside a target's own nested transaction that later raised. Reported as "attempted writes," never as "rows changed."

## 11. Edge-case matrix v3 (M-05/M-07 backlog)

Rows 1–16 unchanged from v0.1; 17–28 from v0.2, with row 17's strategy rewritten. New rows 29–37.

| # | Case | Strategy | Fixture | Milestone |
|---|---|---|---|---|
| 17 | `after_commit` under rollback | **`SetupPlan#isolation` makes both hosts share one regime**; report states which and what it means (was: "consistent suppression" — untrue under truncation) | full | M3 |
| 29 | constructor-argument targets (`.new`, class method, interactor, dry-initializer, struct) | `:construct_subject` step + ctor input generation; unresolvable → `UnresolvableSetup(:opaque_constructor)` | basic + full | M2 |
| 30 | target returns a newly created record with FKs | identity map + FK→ref on all instances + `{t:"seq"}` for unresolvable ids | basic | M3 |
| 31 | app uses DatabaseCleaner `:truncation` / `use_transactional_fixtures = false` | plan `:isolation`; spec emits matching wrapper; M-13 `:isolation_mismatch` | legacy | M2/M3 |
| 32 | first-touch `SCHEMA` / cached / `TRANSACTION` queries | §10 notification filters + declared compare set | basic | M3 |
| 33 | sampled legacy row fails a current validation | `insert_all` import; refetch-diff; `:import_mutated` | legacy | M3 |
| 34 | target reads a redacted attribute | Prism read-detection → `:redaction_read` + spec-header warning | full | M2 |
| 35 | target uses `Time.now` / `Date.today` | `clock_sites` → TZ guard in spec + `:hostile` verify config → `:tz_dependent` | full | M4 |
| 36 | app `rails_helper` forces `queue_adapter = :inline` | emitted `around` forces `:test`; M-13 `:adapter_mismatch` | full | M4 |
| 37 | opaque constructor (`super(dep)`, DI container) | clean refusal naming the superclass or constant | basic | M1 |

## 12. Safety rules v3 (enforced in code, not docs)

1. Env guard — `Rails.env.test?` or explicit confirm.
2. Per-case isolation + a CI row-count proof, Δ across **all** configured connections and under **both** isolation regimes.
3. Read-only sampler + prod-URL hard-confirm.
4. Stdlib-only inspectable probe + `--dry-run`.
5. LLM structurally value-blind.
6. Δ **Never touch specs pinspec didn't write.** pinspec may overwrite its own output (header-provenance identified) and refuses on any file lacking that header; a file whose header is present but whose body has been hand-edited requires `--force`. (v0.2's rule as written either forbade re-pinning or silently clobbered edits.)
7. **Multi-DB scope honesty** — the rollback guarantee covers the primary writing connection. `multi_db: true` → `analyze` and every report say so; fixture CI asserts row counts across all configured connections.
8. **Breach detection** (§11 row 22) — the envelope reports its own failures instead of pretending.
9. Δ **Redaction ON by default**, domain- and length-preserving, with read-detection warnings surfaced in the emitted spec, not only the report; hashed provenance; `--no-redact` prints a committed-spec-files warning and requires confirm.
10. **`DISABLE_SPRING=1`** and Δ **`TZ=UTC`** exported by the sandbox unconditionally.
11. Δ **Rails floor refusal** — Rails < 6.0 exits 10 at `analyze` with the missing-API list, rather than failing at the first `insert_all`.
12. Δ **No raw autoincrement values in any pin.** Sequences are not transactional and do not roll back, so a stored id is unportable by construction. Enforced by the `{t:"seq"}` tag, the zero-literal-id CI grep, and M-13's `:sequence_dependent` diagnosis after `db:test:prepare`.

## 13. Milestones v3

Honest arithmetic first, because v0.2's estimate omitted a line item.

| Module | v0.2 | v0.3 |
|---|---|---|
| M-01 TargetParser | 8 | **14** |
| M-02 SchemaReader | 7 | **8** |
| M-03 FactoryIndex | 6 | 6 |
| M-04 AppProfile | 8 | **10** |
| M-05 ContextBuilder | 28–36 | **34–42** |
| M-06 Inputs | 14 | **18** |
| M-07 Probe | 18 | **25** |
| M-08 StabilityFilter | 7 | **9** |
| M-09 SpecWriter | 14 | **20** |
| M-10 Namer | 5 | 5 |
| M-11 Mutation | 10 | **12** |
| M-12 Report | 6 | **8** |
| M-13 Verifier | 10 | **14** |
| M-14 HostEquivalence | — | **8** |
| M0 scaffold | 8 | 8 |
| Δ **fixture apps** (3 Rails apps, now carrying 9 matrix rows) | **uncosted** | **12–18** |
| **Total** | ~149 + uncosted | **211–225h** |

At a genuine 10h/weekend-day, two days per weekend: **10–13 weekends.** (Higher than the 8–12 in the review, because v0.3 adds M-14 and the fixture line.)

| MS | Scope | Definition of done | Est |
|---|---|---|---|
| **M0** | Scaffold, CI, `rails71_basic`, error taxonomy + exit codes | `pinspec version` green in CI; exit-code table implemented | 1 day |
| **M1** | M-01..M-04 + rows 23, 24, 27, 37 + `analyze` + **mutation-adapter spike** | Analyze correct on both 7.1 fixtures incl. hazard sections; constructor shapes resolved; Rails-floor refusal works; spike answers "can the default backend score a single spec file on a real Rails app?"; **cut `0.1.0`** — standalone pre-engagement hazard report | wknd 1–2 |
| **M2** | M-05 (rows 1–10, 18–20, 25, 28, **29, 31, 34**) + M-06 (hydration, redaction rework, stratified, ctor∪method OFAT) + `plan` | `plan` renders a valid SetupPlan incl. a `:construct_subject`, an import cluster, and an `:isolation` decision for 5 targets; every gating row has a green integration test | wknd 2–5 |
| **M3** | M-07 (identity map, `insert_all` import, SCHEMA filters, two-boot, both isolation regimes) + M-08 + rows 11–17, 21, 22, 26, **30, 32, 33** + `capture` | observations.json on all three fixtures; row-count proof under both regimes and all connections; side-effect capture proof; row-30 target stable across two boots; 6.1 green | wknd 5–7 |
| **M4** | M-09 (helper signature, isolation wrapper, sinks, block matchers, TZ guard) + M-10 + M-13 matrix + **M-14** + rows 35, 36 | **All three verify configs `:green`/`:remedied`, zero manual edits**, on both 7.1 fixtures and `rails61_legacy`, all 3 backends, `--no-llm` included; zero-literal-id grep **plus** ≥1 return/error pin and ≥1 side-effect pin per target; all six M-14 axes green | wknd 7–10 |
| **M5** | M-11 (aspect scoring) + M-12 + `--validate` + real-app demo | On one real OSS app: ≥3 service objects pinned, verify matrix green, ≥1 import cluster, ≥1 constructor-arg target, ≥60% aspects `:strong` (excluding `seq`/truncated pins), **pin** <5 min/target (validate unbounded); report.md client-showable | wknd 10–13 |

Demo candidates unchanged (Docuseal / Solidus / Chatwoot); ship plan unchanged ("Diffblue exists for Java" post + demo report).

### 13.1 Descope levers (new)

If 10–13 weekends is too long, these are the cuts that cost the least:

| Cut | Saves | Costs |
|---|---|---|
| `:inline` snapshot backend only; defer `insta`/`approvals` | ~5h + M4 surface | open question 5 stays open; adapter boundary already isolates it |
| Defer status-stratified sampling to P1 | ~3h | the ubiquitous `case status` service object gets thinner coverage |
| Defer `--annotate`, `--flag-matrix`, blob synthesis | 0 (already P1) | — |
| Drop `rails61_legacy` fixture | ~6h + CI minutes | **loses rows 24, 31, 33 coverage — i.e. the DatabaseCleaner-truncation and legacy-validation findings go untested.** Not recommended; this fixture is where the Tier-1 findings live |
| `--verify-level isolated` as the default | ~4h | reintroduces v0.2's core mistake. Not recommended |

The first two are free money. The last two are the ones that feel like savings and aren't.

## 14. Success metrics

- **Zero-manual-edit rate ≥ 80%**, measured across the **full M-13 matrix** (all three configs `:green`/`:remedied`), not a single isolated run.
- **Strong-aspect ratio ≥ 60%**, with pins bearing `{t:"seq"}` or `:truncated_value` excluded from the numerator.
- Δ **Time split:** `pin` (plan + capture + emit + verify matrix) **< 5 min/target**. `--validate` is **explicitly outside the budget** — mutation-testing one method on a real Rails app runs 5–30 min, and v0.2 stated both numbers as if one run produced them.
- Δ **All six M-14 axes green** in CI on every commit. This is the leading indicator; the DoD is the lagging one.
- Lagging: client engagement, 100 stars on the M1 release, first external-app issue report.

## 15. Open questions & decision log

**Locked (v0.1):** two-process stdlib probe · RSpec-only · service objects + models · `:inline` default · mutineer default (licensing) · LLM names-only · no Faker.

**Locked (v0.2):** plan-time hydration · one-source serializer template · refs replace IDs · side-effect capture ON · redaction ON · verification in the default `pin` path.

**Locked (Δ v0.3):**
- Gem name **`pinspec`**; `pinion` is squatted (Task 0 closed)
- Constructors are part of the invocation surface — `:construct_subject` and ctor input generation
- Identity is a value-level rule: FK→ref on **every** AR instance; `{t:"seq"}` for the unresolvable rest; no raw autoincrement value in any pin
- Isolation is a plan property, symmetric across hosts, stated in the report
- The stability compare set is declared, and excludes SQL (unless pinned) and `duration_ms`
- Imports use `insert_all` + refetch-diff; target Rails floor **6.0**
- Verification is a 3-config matrix; DoD includes positive coverage
- `normalize(value, refs:, fk_map:)`
- **Two boots by default**; `--fast` opts into in-process shuffle with a stated blind spot
- Redaction is **domain- and length-preserving** with read-detection surfaced in the spec
- Sample DB defaults to **development-if-populated**
- M-14 exists: host equivalence is a build-breaking test

**Open (owner: Rehan):**
1. ~~Gem name~~ — closed: `pinspec`.
2. `structure.sql` — re-check when the demo app is chosen; candidate `pg_query`, CLI-side.
3. Float tolerance config — defer until a demo target hits `:float_noise`.
4. `db_delta` table-level detail — P1.
5. Insta as recommended backend — revisit at M4; adapter isolates.
6. Bulk mode via Skunk scores — P2, on real usage.
7. ActiveStorage blob synthesis (row 18) — P1, after the first real-app `:attachment` refusal.
8. `--annotate` LLM bug-flag prose — P1, audit-deliverable sweetener.
9. `--flag-matrix` (pin Flipper branches both ways) — P1, parked.
10. Δ **Rails 5.2 support** — needs a hand-rolled multi-row insert and a `CurrentAttributes` shim. Decide only if a real prospect is on 5.2; the floor is 6.0 until then.
11. Δ **Re-pin / accept workflow** — when the app legitimately changes and pins go red, there is no `pinspec diff` or `re-pin --accept`. Not v1-blocking; it will surface on day 2 of the M5 engagement, so it is a named P1 rather than a discovery.
12. Δ **Ctor case-space policy** — the round-robin allocation in M-06 is a guess. Revisit once real targets show whether constructor params or method params carry the branching.

## 16. First working session (~2h)

1. `bundle gem pinspec` scaffold; claim `pinspec` on rubygems (name verified free 2026-08-11).
2. `rails71_basic` fixture: models covering matrix rows 1–5, **plus a row-30 target** (`#call` on a class whose `initialize` takes the invoice, returning a newly created record with a FK). That one target exercises the two largest v0.3 changes and is the regression test you'll run a thousand times.
3. CI: unit + fixture boot + probe `ruby -c` 2.6 guard + the zero-literal-id grep + an empty `spec/equivalence/` harness that already runs.
4. First failing M-01 spec — `construction_kind` on the row-30 target.
5. Open M-01..M-04 issues with the acceptance checklists pasted in, and the M-11 spike as a timeboxed M1 issue.

Start there. Everything after is the matrix, one row at a time — and M-14 is what tells you when a row that was green stopped being green.
