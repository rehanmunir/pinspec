# Adversarial review — Pinion/pinspec technical spec v0.2

**Reviewer:** Claude · **Date:** 2026-08-11 · **Reviewing:** spec v0.2 (Aug 2026)
**Method:** hunt for the same failure class that killed v0.1's M4 DoD — contracts that hold inside one host (plan time / probe process / spec process) but silently break across the boundary between them.

## Verdict

v0.2's five structural fixes are the right fixes. Symbolic refs, side-effects-as-observations, and a verification stage are exactly what v0.1 was missing, and "one serializer, two hosts" is the correct organizing principle.

But that principle is only applied to **value encoding**. Three other things also live in two hosts and are not unified: **record identity for records the target creates**, **transactional isolation**, and **side-effect sink lifecycle**. Each is a live reprise of the v0.1 failure class. Separately, the spec has one flat omission that blocks its own headline example.

Findings: **6 that block the M4/M5 DoD**, **6 that produce silently-wrong-but-green pins**, **4 cost/process**, plus minors.

Gem name: `pinion` is taken on rubygems.org (cespare/pinion, Rack asset compiler, v0.3.2, 2013, ~50k downloads). Locked to **`pinspec`**; module `Pinspec`, exe `pinspec`. All §-references below are to v0.2 as written.

---

# Tier 1 — blocks the DoD

## T1-1 · No constructor support. The headline example does not work. (§6 TargetProfile, §7 M-01, M-05, M-06)

**What the spec says.** `TargetProfile` carries `params` (the *method's* params), `visibility`, `takes_block`, `source_range`, `referenced_constants`. M-01's behavior is "locate class/module, instance vs class method, param kinds + default sources." M-05 rule 1: "Root records: params with model hints + subject record **for model-instance targets**."

**What breaks.** The spec's one-sentence product is:

```
pinspec pin app/services/invoice_calculator.rb#call
```

The dominant Rails service-object shape puts dependencies in `initialize` and exposes a **zero-argument** `call`:

```ruby
class InvoiceCalculator
  def initialize(invoice, tax_engine: TaxEngine.new) = ...
  def call = ...
end
```

Nothing in the spec parses `initialize`, plans a subject construction, or generates constructor inputs. `TargetProfile` has no `initializer_params`; `InputCase` has no `ctor_args`; `SetupPlan` has no `:construct_subject` step; M-05 only builds a subject for *model* instance targets. So for the flagship target the probe has no way to reach `.new`, and `--cases 12` of boundary values are generated for a method that takes nothing.

This is invisible on a read-through precisely because `#call` is used as the example everywhere — the reader supplies the constructor mentally.

**Fix.**
- `TargetProfile += :initializer_params, :construction_kind` where `construction_kind ∈ {:new, :class_method, :interactor, :dry_initializer, :struct}`. Detect: `def initialize`, `Struct.new`/`Data.define` superclass, `option`/`param` (dry-initializer), `include Interactor`, `attr_reader` + `def self.call(...) = new(...).call`.
- `InputCase += :ctor_args, :ctor_kwargs`.
- `SetupPlan += :construct_subject {class:, args:, kwargs:}` — ordered after record creation, before invocation.
- M-06 generates over `ctor_params ∪ method_params` with OFAT held to the same `--cases` cap (all-defaults-first still first).
- Inherited `initialize` and `super` chains: resolve one level statically, else `UnresolvableSetup(:opaque_constructor)` naming the superclass. Refusing is fine; being silent is not.

**Cost.** +6h M-01, +4h M-05, +3h M-06. **This is the largest single omission in the document** and it lands squarely on the gating path for M2 and M4.

---

## T1-2 · Ref rewriting doesn't cover records the target creates — so the v0.1 ID class survives, as a *stability* failure (§9, §6, §7 M-07)

**What the spec says.** §9 row 1: "AR instance, **plan-created or imported** → `{class:, ref:, attributes:}`; id dropped; FK attrs pointing at plan records → refs." §9 row 2: "AR instance, **other** → `{class:, attributes:}`, no id — appears only via target-internal creation."

The ref-rewriting clause is attached to row 1 only. Row 2 drops the id and keeps every other attribute verbatim.

**What breaks.** The single most common service-object return value is *the record it just created*:

```
probe:  plan creates Customer → id 41.  Target creates Invoice(customer_id: 41).
        serialize → {class: "Invoice", attributes: {customer_id: 41, total: "19.99"}}
spec:   let! creates Customer  → id 87.  Target creates Invoice(customer_id: 87).
        normalize → {class: "Invoice", attributes: {customer_id: 87, ...}}   → RED
```

It is worse than red, because **Postgres sequences are not transactional and do not roll back**. Run 1 case c003 sees `customer_id: 41`; run 2 (same process, sequence advanced) sees `customer_id: 53`. So:

1. StabilityFilter flags the case unstable and **drops it before M-13 ever runs**.
2. The cause taxonomy (§7 M-08: `:time`, `:random`, `:float_noise`, `:order_dependent`, `:escaped_transaction`, `:external_io` fallback) has no entry for id churn, so it reports `:external_io` — "external I/O, consider WebMock" for a target that made no network call. A misleading diagnosis on the most common target shape.
3. Net user experience: *"pinspec found nothing stable to pin"* on `InvoiceCalculator#call`.

And if such a case ever did survive to M-13, the diagnosis table routes id-shaped diffs to `PinionInternalError` — the spec correctly predicts the symptom while the design has no mechanism to prevent it.

**Fix.**
- Ship the FK map into the probe. `cases.json` must carry `fk_map: {"invoices.customer_id" => "customers", ...}` derived from `SchemaGraph`. **It currently carries only `plan_id`, `setup_plan`, `cases`** — the probe has no way to know which integer is a foreign key.
- Probe maintains a live `{table, pk} → ref` identity map, populated by `:create_record` and `:import_record`.
- Serializer rewrites **every** attribute on **every** AR instance (both §9 rows) whose column is a known FK and whose value hits the identity map → `{t:"ref", v:"customer_1"}`.
- Unresolvable id-shaped values (the record's own PK, ids of other target-created rows, `*_ids` arrays) → new tag `{t:"seq"}`: a wildcard that asserts "an autoincrement integer is present here" and compares equal to any Integer. Preserves shape, pins nothing unpinnable. Report counts `:seq` occurrences as a coverage caveat.
- `StabilityFilter` gains cause `:identity_churn` so any case that still churns gets a truthful diagnosis.
- Also state plainly in §12: **rollback does not reset sequences**; any pin containing a raw autoincrement value is unportable by construction.

**Cost.** +3h M-07, +2h M-08, +1h M-02 (emit fk_map). Cheap. Skipping it costs M4.

---

## T1-3 · Probe isolation ≠ spec-host isolation. `db_cleaner: :truncation` diverges the two hosts. (§3, §7 M-07/M-09/M-13, §11 row 17)

**What the spec says.** Probe wraps each case in `transaction(requires_new: true)` and rolls back; `after_commit` therefore never fires; row 17 says this is "suppressed **consistently in probe *and* spec**, divergence from production documented." M-04 detects `db_cleaner ∈ {:transaction, :truncation, :none}` as "M-13 diagnosis input."

**What breaks.** The spec detects the very condition that falsifies its own consistency claim and then only uses it for post-hoc diagnosis. When the app's `rails_helper` uses DatabaseCleaner `:truncation` (or sets `use_transactional_fixtures = false` — routine in legacy apps configured in the Capybara-with-a-real-driver era), examples are **not** wrapped in a transaction. In the emitted spec:

- `after_commit` / `after_create_commit` **do** fire — they never fired in the probe.
- Those callbacks enqueue jobs and send mail, so `enqueued_jobs` / `mail_deliveries` pins get extra entries.
- M-13 sees red. Its diagnosis table has a DatabaseCleaner entry, but it covers *strategy errors* — "append documented strategy note, **no retry**". So the run ends `:failed` with a note, on a large and predictable slice of real apps.

The inverse is worse: a target whose only observable behavior is an `after_commit` side effect pins as "returns true, no jobs" in the probe, and if the spec host *does* run truncation the pin goes red for the right reason but gets diagnosed as an app-config quirk. Either way the harness is wrong about what the code does.

**Fix.** Make isolation an explicit, symmetric plan property rather than an assumption:
- `SetupPlan += :isolation` — `:transaction` (default) or `:truncation`, decided at plan time from `AppProfile#db_cleaner` / `use_transactional_fixtures`.
- `:transaction`: probe rolls back (as today) **and** SpecWriter emits an `around` hook that forces a transaction regardless of the suite's strategy:
  ```ruby
  around { |ex| ActiveRecord::Base.transaction(requires_new: true) { ex.run; raise ActiveRecord::Rollback } }
  ```
  and the spec header states that `after_commit` is suppressed in both hosts.
- `:truncation` (opt-in, or forced when the app disables transactional fixtures): probe runs **without** the wrapper and cleans by truncating the tables it touched; `after_commit` fires in both hosts; report notes DB-mutating capture.
- M-13 diagnosis gains `:isolation_mismatch` with a remedy-retry that flips the plan's isolation once — that's a legitimate mechanical fix, unlike a strategy note.
- §11 row 17's strategy text needs rewriting: consistency is a thing you *enforce*, not a thing you get.

**Cost.** +4h M-09, +3h M-07, +2h M-13. Add a fixture: `rails61_legacy` should use DatabaseCleaner truncation — it's the realistic legacy config and it exercises this row.

---

## T1-4 · `SCHEMA` / `CACHE` / `TRANSACTION` notifications make run 1 ≠ run 2 for every first-touch case (§10, §7 M-07/M-08)

**What the spec says.** §10 normalizes literals to `?`, collapses `×N`, drops savepoints, and filters an ignore-**tables** list. M-08 "joins run1/run2 by case_id; **deep-compare**."

**What breaks.** `sql.active_record` fires for Rails' own column/type introspection with `payload[:name] == "SCHEMA"`, once per model class per process. Run 1's first case touching `Invoice` logs those; every later case — and **all of run 2, which shares the process** — does not. Query-cache hits arrive with `payload[:cached]` set. `BEGIN`/`COMMIT` arrive under name `TRANSACTION` in current Rails.

So on a straight deep-compare, the first case to touch each model diverges between runs and is discarded as unstable. With `--cases 12` across a handful of models that is a meaningful fraction of every corpus, discarded for a reason that has nothing to do with the code under test. In `--paranoid` mode (fresh process for run 2) it reappears symmetrically and turns into *cross-case* noise instead.

**Fix.**
- §10 filters by `payload[:name] ∈ {"SCHEMA", "TRANSACTION", nil-with-DDL}` and skips `payload[:cached]` entries, in addition to the ignore-tables list.
- §7 M-08 must state that **`sql_fingerprints` is excluded from the stability decision unless SQL pins were requested**. As written, "deep-compare" over the whole `Observation` makes SQL the most fragile field in the record decide the fate of every pin — and SQL pins are opt-in, so it's fragility with no upside by default.
- Same for `duration_ms`, which is in `Observation` and is never equal between runs. The spec never says which fields participate in the comparison; that list needs to be explicit: `status`, `return_value`, `error`, `enqueued_jobs`, `mail_deliveries`, `db_delta`, and `sql_fingerprints` only when pinned.

**Cost.** +2h. This is a day-one "everything is unstable" bug; catching it in prose is worth an evening.

---

## T1-5 · `:import_record` via `create!` cannot import the rows worth importing — and there is no minimum target-Rails floor (§7 M-06/M-07, §0)

**What the spec says.** M-07: ":import_record = `Model.create!(attrs-with-refs-resolved)`". The replan remedy table handles "validation failure on `:create_record` → retry factory traits"; nothing covers `:import_record`.

**What breaks — two ways.**

1. **Legacy rows fail current validations.** That is the entire reason these codebases are frightening. A 2018 row predating `validates :email, presence: true` raises `RecordInvalid` on `create!`. Traits don't apply to imports, so the remedy table has no move and the case becomes `setup_error`. The most valuable inputs — real, weird, historical rows — are systematically the ones that fail to import, and the tool degrades to boundary scalars exactly where sampling was supposed to earn its keep.
2. **Callbacks rewrite the world you asked for.** `create!` fires `before_validation`/`before_save`. You import `total: 0.00` and a recompute callback stores `199.00`. The probe then pins behavior over a world that is neither production's nor the plan's, and **nothing detects it** — the spec is internally consistent, M-13 is green, and the snapshot is fiction.

**Fix.**
- `:import_record` uses `Model.insert_all([attrs])` (skips validations *and* callbacks), then refetches by the returned PK to bind the ref. Fall back to `save!(validate: false)` only when `insert_all` is unavailable, and **flag the observation** when the fallback is used, because callbacks then ran.
- Post-import verification: refetch and diff against the requested attrs; any mutated column → report note + `:import_mutated` flag. Cheap, and it converts a silent lie into a visible caveat.
- **Declare a minimum target Rails version.** `insert_all` needs 6.0+; `connects_to` (M-04 multi-DB) is 6.0+; `CurrentAttributes` is 5.2+. The spec pins a *Ruby* floor for the probe (2.6-safe) and never states a Rails floor, while M-04..M-07 rely on several 6.0+ APIs. Ruby 2.6 + Rails 6.0/6.1 is a coherent floor — say so in §0, and gate M-04 on emitting a clean refusal below it.

**Cost.** +3h M-07, +1h M-04.

---

## T1-6 · M-13 green proves same-machine reproducibility, not portability — so §14's headline metric measures the wrong thing (§7 M-13, §13 M4/M5, §14)

**What the spec says.** M-13 runs `bundle exec rspec <spec_path> --format json` in the app dir. M4's DoD is `:green`/`:remedied` with zero manual edits. §14: "zero-manual-edit rate is now *measured by M-13*."

**What breaks.** The verifier runs on the same machine, minutes later, with the same TZ, same locale data, same collation, same sequence positions, same seed data, in the same file, alone. Every failure mode that actually bites a client is invisible to it:

| Failure | Why M-13 misses it |
|---|---|
| CI runs `TZ=UTC`, dev machine doesn't (or vice versa) | same process env both times |
| Fresh `db:test:prepare` resets sequences | same DB state both times |
| Postgres collation orders the `{t:"relation", first:[…]}` cap differently | same DB both times |
| Parallel workers (`TEST_ENV_NUMBER`) | single-worker run |
| `ActionMailer::Base.deliveries` accumulating across examples | one example, one file |
| Another spec leaves `Flipper` enabled / `Current.user` set / a memoized class ivar warm | file run in isolation |
| RSpec random ordering | default seed, single order |

That last row is the tell: the harness's own `--paranoid`/shuffle discipline is applied to the *probe* and dropped for the *verifier*, which is the host whose behavior we actually promise.

**Fix — cheapest high-value change in this review.** Same command, different env. Make M-13 a matrix:

1. `:green_isolated` — as today.
2. `:green_hostile` — `TZ=Etc/GMT+8 LANG=C LC_ALL=C`, after `db:test:prepare` (fresh sequences), `--seed` different.
3. `:green_neighbored` — the emitted file **twice in one process** (`rspec f.rb f.rb`) plus alongside one sibling spec from the app's suite. Catches sink accumulation and leaked global state, the two most common "passes alone, fails in suite" causes.

Report the three outcomes separately; M4's DoD requires all three; §14's ≥80% metric is measured against the matrix, not against run 1. Diagnosis gains `:tz_dependent`, `:sequence_dependent`, `:suite_contaminated`.

Also: **M4's DoD needs a positive-coverage assertion.** "Emitted spec contains zero literal DB ids (grep-able)" passes trivially when the tool emitted no pins at all — which is precisely what T1-2 causes. Add: ≥1 return-or-error pin and ≥1 side-effect pin per fixture target, and a fixture target that returns a newly created record with a FK.

**Cost.** +4h M-13, +2h M-12. "Green path adds < 30s" becomes ~90s on fixtures; on the M5 real app expect 2–4 min. Worth it — it is the difference between measuring the DoD and asserting it.

---

# Tier 2 — silently wrong pins (green, and lying)

## T2-1 · `PinionSerializer.normalize(result)` cannot resolve refs — the signature is wrong (§7 M-09, §4c)

The helper's job in the spec host is the *inverse* of the probe's: turn a live AR instance into `{t:"ref", v:"invoice_1"}`. That requires the spec's own ref table (`{"invoice_1" => <the let!-bound record>}`), and the stated call site is `PinionSerializer.normalize(result)` — one argument, no table, no registry. As specified it cannot do the thing §4c is built around.

**Fix.** `PinionSerializer.normalize(result, refs:, fk_map:)`, with the emitted setup building `let(:pinspec_refs) { {"invoice_1" => invoice_1, ...} }` and `fk_map` inlined as a frozen constant in the generated helper. Both come from the same template as the probe encoder, so the two hosts stay locked. Also state the `refs` table is keyed by ref string, populated in plan-step order, and that a ref appearing in a snapshot with no entry in the table is a `PinspecInternalError`, not a failed expectation — a missing ref is our bug and should not look like a behavior change.

## T2-2 · Side-effect capture is not symmetric across hosts (§7 M-07, M-09, M-13)

The probe's discipline is precise: force `:test` adapters, clear sinks **after setup, before target**, capture after. The spec host gets none of that guaranteed.

- **Matcher form.** M-09 emits `have_enqueued_job(SyncJob).with(...)`. In rspec-rails `have_enqueued_job` is a **block** matcher (`expect { subject }.to have_enqueued_job`); the non-block form is `have_been_enqueued`. Emitted in non-block form, setup enqueues count toward the pin and it is wrong in the permissive direction. Emit block form, always.
- **Adapter mismatch.** If the app's `rails_helper` sets `queue_adapter = :inline`, or wraps examples in `perform_enqueued_jobs`, jobs execute instead of queueing and every job pin sees zero. M-13's diagnosis table has no entry for this. The emitted spec must force `ActiveJob::Base.queue_adapter = :test` in an `around` (restoring after), and M-13 needs `:adapter_mismatch`.
- **Deliveries lifecycle.** `ActionMailer::Base.deliveries` is not cleared per example unless the app or a helper does it. Two pinned examples in one file: the second's mail count includes the first's. Emit `before { ActionMailer::Base.deliveries.clear }` and force `delivery_method = :test`.
- **Sink clear point.** The spec host has no equivalent of "clear after setup, before target" unless the matcher is block-form — which is the real reason block form is mandatory, not style.

This is the same gap as T1-3 in a different subsystem: **"one serializer, two hosts" is enforced for values and assumed for everything else.** §4 should be restated as *one contract, two hosts*, covering encoding, isolation, sinks, clock, locale, and zone — with a CI test per axis asserting probe and emitted spec agree.

## T2-3 · Redaction ON by default pins behavior that never happens (§7 M-06, §12.9, §11 row 28)

The spec sees this and mis-sizes it: "Redaction can change behavior (a target regexing on email domain now sees `example.test`) — every redacted field is listed in the report." A report footnote does not fix a wrong pin. The chain is: redact at hydration → probe observes redacted-world behavior → spec reproduces redacted-world behavior → M-13 green → snapshot committed as the frozen truth of a code path that never runs that way in production. The tool's single promise is "freeze current behavior," and this is the one mechanism that breaks it while looking correct.

**Fix, in order of value:**
1. **Domain- and length-preserving redaction.** `rehan.munir@acme.co` → `person1.aa@acme.co`, not `user1@example.test`. Keeping the domain kills the largest behavioral blast radius (domain routing, allowlists, `split("@").last`); keeping length kills the second (truncation, `validates length`). Free-text names → same-length `Person{n}` padded.
2. **Read detection.** Prism-scan the target for each redacted attribute name (symbol, string, `record.email`, `[:email]`). A hit → per-case warning at the top of the emitted spec and a `:redaction_read` flag on the observation, not a report footnote. Honest limit: transitive callees are invisible; say so.
3. Keep `--no-redact` and its warning.
4. Make the provenance comment (`# imported from sample:invoices:4213`) hash the source id by default. A spec file committed to a regulated client's repo that maps fixtures to production row ids is its own governance conversation, and the audit-deliverable buyer is exactly the buyer who will raise it.

## T2-4 · `Time.now` / process TZ is invisible to *both* safety nets (§7 M-05 rule 7, §11 row 25)

`:set_locale` and `:set_zone` set `I18n.locale` and `Time.zone`. A target calling `Time.now`, `Time.new`, or `Date.today` — endemic in legacy code — reads the **process** zone, which `Time.zone` does not govern. Both runs share a machine, so StabilityFilter cannot see it; M-13 shares the machine too (T1-6), so it cannot either. The pin ships green and fails on the client's CI. That is the worst available failure shape: undetectable locally by construction.

**Fix.** Detect `Time.now` / `Time.new` / `Date.today` / `DateTime.now` in the target source (same Prism scan that finds `Flipper.enabled?` — this is what `referenced_constants` should be feeding). On a hit: emit a header warning naming the line, add a spec-level guard that fails loudly if `ENV["TZ"]` differs from the capture-time value, and record `:tz_dependent` in the report. Sandbox exports `TZ=UTC`; the emitted spec cannot set its own process TZ before boot, so a guard plus the hostile-config run (T1-6) is the honest answer. Also pin the freeze mechanism explicitly in §9 — `travel_to`'s sub-second truncation is version-dependent, and both hosts must use the identical call with identical `with_usec` behavior.

## T2-5 · Sampling defaults to the app's **test** DB, which is empty (§5, §7 M-06, §13 M5)

`--sample-db URL` defaults to the app test DB. Test DBs are empty or fixture-seeded, so by default there are **zero import clusters, zero sampled cases, and zero status-stratified coverage** — the default configuration silently disables the module the whole v0.2 hydration rewrite was built for. Meanwhile M5's DoD requires "≥1 target exercising an import cluster" on a real OSS app, whose test DB is also empty.

The v0.2 hydration change is what makes the better default *safe*: sampling is read-only and happens at plan time in the CLI process, so it can read the **development** DB while the probe runs `RAILS_ENV=test` without any connection crossing.

**Fix.** Default to `development` if it resolves and has rows in the target's tables, else `test`, and print which was used and how many rows it found. When zero rows: a loud one-liner — "no sampled rows found; corpus is boundary-only, coverage will be thin" — because that is the difference between the tool's demo and its default.

## T2-6 · Truncation and capping weaken pins without saying so (§9, §6)

`Observation#flags` includes `:truncated_value` and nothing consumes it. Depth-cap 4 and `--max-collection 50` mean a snapshot can compare equal while everything below depth 4 or past element 50 changed freely. M-11 will eventually label those pins weak, which is the self-correcting path — but only under `--validate`, which is opt-in. Surface truncation counts in the report as an explicit coverage caveat, and exclude `{t:"seq"}`/`:truncated_value`-bearing pins from the "strong aspect" numerator in §14 so the metric can't be inflated by pins that assert less than they appear to.

---

# Tier 3 — cost, process, and one metric that can't be met

## T3-1 · Replan granularity is unspecified and the cheap answer is the right one (§7 M-05.12, M-07)

`SetupPlan` is per-target; `setup_error` is per-case. One pathological case (a `nil` boundary where a NOT NULL FK is required) triggers a replan of the whole plan, which changes `plan_id`, which invalidates observations stamped with the old one — up to 3 generations × 2 runs of full probe boots, and nothing says whether good observations survive.

**Fix.** Quarantine-first: a `setup_error` drops that case with a report line, plan unchanged. Replan only when **all** cases setup-error (a genuinely broken plan) or when the error is one the remedy table can act on globally (uniqueness → bump namespace). Keep the 3-generation cap for that path. Also: uniqueness remedy must re-salt **imported** unique columns, not just the `-p{n}` counter on created records — a seed-data collision on an imported email is unreachable by the current remedy and will loop to `:failed`.

## T3-2 · `--paranoid` should be the default; in-process shuffle cannot see first-touch memoization (§7 M-07, §15 locked list)

Run 2 in the same process inherits every warm cache from run 1. An input-keyed memo (`@rate ||= compute(customer)`) is filled by run 1's first case and reused by every later case **and all of run 2** — so run 1 and run 2 agree, the pin looks stable, and its value is an artifact of whichever case happened to run first. A fresh process with a different first case produces a different snapshot. The acceptance criterion as written ("class-ivar memoization fixture → run-2 shuffle produces a divergent observation") passes only for a memo whose *presence* is input-dependent; it encodes a stronger general claim than shuffle can support.

Given the product's third goal is determinism and a boot costs 10–30s, two boots by default is cheap insurance. **Flip it:** two boots default, `--fast` for in-process shuffle, and keep the shuffle inside *both* boots (it still catches genuine order dependence). This contradicts a v0.2-locked decision; the locked decision is the wrong side of a 20-second trade.

## T3-3 · `--validate` cannot fit inside "<5 min/target", and it gates M5's DoD on an unvalidated dependency (§14, §13 M5, §7 M-11)

Mutation-testing one method on a real Rails app is routinely 5–30 min. §14's `<5 min/target` and M5's `≥60% aspects :strong` are stated together as if one run produces both. Split the metric: **pin** <5 min/target; **validate** unbounded and opt-in.

Bigger risk: the default backend is chosen on licensing grounds, and M5's DoD depends on it producing per-aspect scores on a real Rails app. That dependency is unproven and it gates the final milestone. **Spike the mutation adapter at M1** — two hours against `rails71_basic` is enough to learn whether the default backend can boot the app, target a `source_range`, and run a single spec file. If it can't, you want to know in weekend 1, not weekend 8.

## T3-4 · The estimate omits the fixture apps, and they're the CI tax (§8, §13)

Module efforts sum to ~141–149h; M0 adds ~8h. Nowhere is the cost of **three Rails apps** counted — and v0.2 grew their requirements: `rails71_full` now needs paper_trail, flipper, an `after_commit` that enqueues, an enum status column, and a seeded `before(:suite)` unique-collision trap; `rails61_legacy` needs factory_girl (and, per T1-3, DatabaseCleaner truncation). That's 12–18h of app-fiddling plus ongoing rot. Real total ≈ 165–175h. At a genuine 10h weekend-day that is **8–12 weekends**, not 6–8.

Also: committing three Rails apps means CI `bundle install`s three Rails apps per run. Commit the `Gemfile.lock`s, cache aggressively by lock hash, and consider generating the fixtures from a script with committed locks rather than committing full trees.

---

# Minors (one line each)

- **cases.json arg encoding undeclared.** §6 shows `cases: [{id, args, kwargs}]` with no statement that args use serializer-v2 tags or that the probe resolves `{t:"ref"}` before invocation. Declare it; it's the second-most-crossed boundary in the system.
- **kwargs symbolization + the 2.6 empty-splat wart.** JSON keys are strings; the probe must symbolize. And `**{}` forwarding behavior differs pre-2.7 — invoke through one version-guarded shim in the template, not inline at each call site.
- **`referenced_constants` is collected and never used.** It's the natural feed for Flipper detection (M-05.9), attachment detection (M-05.11), and `Time.now` detection (T2-4). Wire it or drop it.
- **`--unsafe-env` requires an interactive confirm** with no non-interactive escape; it will deadlock or fail opaquely in CI. Add `PINSPEC_UNSAFE_CONFIRM=1`.
- **Exit-code taxonomy is referenced, never tabulated.** M-01's acceptance requires "exit code distinct from `TargetNotFound`". For a scriptable CLI this belongs in §5 as a table.
- **Never-touch-existing-specs needs a self-carve-out.** Re-running `pin` on the same target must be able to overwrite *its own* previous output (identified by header provenance), and must refuse on any file lacking that header. As written the rule either forbids re-pinning or silently clobbers hand edits — and users will hand-edit pinned specs.
- **No story for week two.** When the app legitimately changes and pins go red, there's no `pinspec diff` / `re-pin --accept`. Not v1-blocking; it will surface on day 2 of the M5 client engagement, so it belongs in §15 as a named P1 rather than a discovery.
- **`db_delta` overcounts.** Derived from the SQL log (it must be — the transaction is rolled back before you could count rows), so writes inside a target's own nested transaction that later raised are still counted. Note it, or say `db_delta` counts *attempted* writes.
- **`{t:"relation", total:}`** is stable only while the sampled cluster is; state that `total` is a plan-dependent value and re-sampling changes it (so a re-pin after new sampling is a legitimate diff, not a regression).
- **`skipped_statements` has no `analyze` exit-status effect.** A `create_view` on a table the plan must fill is materially different from one it never touches; make the surfacing conditional on relevance or it becomes noise everyone ignores.

---

# What v0.3 should change in the locked lists

**Contracts that must change (breaking v0.2):**

1. `TargetProfile += :initializer_params, :construction_kind` · `InputCase += :ctor_args, :ctor_kwargs` · `SetupPlan += :construct_subject` — T1-1
2. `cases.json += fk_map` · serializer rewrites FKs → refs on **all** AR instances · new tags `{t:"seq"}` · `StabilityFilter += :identity_churn` — T1-2
3. `SetupPlan += :isolation` · SpecWriter emits a matching isolation wrapper · M-13 `+= :isolation_mismatch` with a flip-once remedy — T1-3
4. §10 filters `SCHEMA`/`TRANSACTION`/`cached` · §7 M-08 names the exact fields that participate in the stability compare (SQL and `duration_ms` excluded by default) — T1-4
5. `:import_record` uses `insert_all` + refetch-and-diff · declare a **minimum target Rails version** in §0 — T1-5
6. M-13 becomes a 3-configuration matrix (isolated / hostile / neighbored); §14's ≥80% measured against the matrix; M4 DoD gains a positive-coverage assertion — T1-6
7. `PinspecSerializer.normalize(result, refs:, fk_map:)` — T2-1
8. Emitted specs force `:test` adapters, clear deliveries per example, and use **block-form** job matchers — T2-2

**Locked decisions to revisit:**

- *"Run-2 shuffle default; `--paranoid` two-boot opt-in"* → **invert** (T3-2).
- *"Redaction ON by default, format-preserving"* → keep ON, redefine format-preserving as **domain- and length-preserving**, add read-detection (T2-3).
- *"§4 one serializer, two hosts"* → restate as **one contract, two hosts** across encoding, isolation, sinks, clock, locale, zone — with a per-axis CI equivalence test (T1-3, T2-2, T2-4).
- Sample-DB default: test → **development-if-populated** (T2-5).

**Schedule:** 6–8 weekends → **8–12**, with the fixture-app build costed as its own line item, and the mutation-adapter spike pulled forward to M1 (T3-3, T3-4).

---

# What survives review unscathed

Worth saying, since the above is all objection:

- **Plan-time hydration** is the correct fix and it does kill the class it claims to (for *imported* records — T1-2 is about a different record population).
- **Two-process, stdlib-only, inspectable probe with `--dry-run`** is the right architecture and the right trust posture for a tool that runs inside a client's app.
- **Refusal over fabrication** — `BlockRequired`, `UnresolvableSetup(:attachment)`, `:escaped_transaction`, and explicitly declining `after_commit` fidelity. Every one of those is a place a lesser design would have guessed and shipped a lie. The instinct is the product's actual moat.
- **LLM structurally value-blind.** Not "prompted not to"; unable to. That's the correct construction.
- **`analyze` as a standalone shippable at M1.** A pre-engagement hazard report has real value on its own, and with M-04's v0.2 growth it's now genuinely a product rather than a milestone artifact.
- **Aspect-level mutation scoring.** Grading a job pin independently of a return pin is the insight that makes the vacuous-`true` service object scoreable at all.
