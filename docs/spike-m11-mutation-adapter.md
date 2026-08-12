# Spike: M-11 mutation adapter

**Timeboxed spike, 2026-08-11.** Pulled forward from M5 to M1 on the review's
recommendation (T3-3): M5's definition of done gates on "≥60% of aspects
`:strong`", which depends on a backend nobody had proven can boot a Rails app,
target one method, and score a single spec file. Learning that in weekend 1 costs
two hours; learning it in weekend 11 costs the milestone.

**Verdict: keep `mutineer` as the default. It clears every requirement.** Three
spec contracts need correcting (§6, §7 M-11, §7 M-09), one of which is that
`--validate` raises pinspec's Ruby floor from 3.2 to 3.4.

---

## 1. The question

Spec v0.3 §7 M-11 assumes a backend that can:

1. run against an RSpec suite (pinspec emits RSpec only — a v0.1 locked decision)
2. target a single subject, so mutants land in the pinned method and nowhere else
3. run one spec file, not the app's whole suite
4. emit machine-readable results, so `PinScorer` can grade **per aspect**
5. work on the Ruby a legacy Rails app actually runs (2.6–3.x, per §0.1)
6. carry a license that does not entangle a client's codebase

`mutineer` was chosen in v0.1 on point 6 alone. Nothing else had been checked.

## 2. Candidates as they actually stand

| | `mutineer` | `mutant` / `mutant-rspec` | `mutest` |
|---|---|---|---|
| Version | 0.11.4 | 0.16.3 | 0.0.10 |
| License | **MIT** | Nonstandard (commercial for closed source) | MIT |
| Total downloads | 4,710 | 1,899,216 | 42,161 |
| First release | ~2026-07-01 | mature | — |
| Last release | 2026-07-29 | 2026-04-30 | **2019-02-11** |
| Runtime deps | **none** (Prism + stdlib) | several | — |
| Ruby required | **>= 3.4** | wide | old |

`mutest` is a dead 2019 fork — excluded. So the real choice is a brand-new MIT
tool versus a mature one whose license is the reason v0.1 avoided it.

**The rubygems description for mutineer is stale** and says it runs "your
Minitest suite". The README and the CLI both support RSpec. Reading only the gem
metadata would have rejected the right answer.

## 3. What was actually run

A subject with **both a return value and a side effect**, which is the shape
pinspec has to grade per aspect:

```ruby
def call
  total = @invoice[:subtotal] * (1 + @tax_rate)
  total = total.round(2)
  ENQUEUED << { job: "SyncJob", total: total }   # stands in for perform_later
  total
end
```

…scored against four different spec files. All runs used
`--only "InvoiceCalculator#call" --framework rspec`.

| Spec file | Asserts | Score | Killed |
|---|---|---|---|
| `strong_spec.rb` | return **and** enqueue | **80%** | 4/5 |
| `vacuous_spec.rb` | only that it returns truthy | **20%** | 1/5 |
| `return_aspect_spec.rb` | return only | **60%** | 3/5 |
| `job_aspect_spec.rb` | enqueue only | **80%** | 4/5 |

### Findings, in order of importance

**(a) It discriminates a strong pin from a worthless one — 80% vs 20%.** That is
§14's metric working. Without this separation the metric is decoration.

**(b) Per-aspect scoring works, and the mechanism is one run per aspect.** The
return-only run's survivor list *includes the mutant that deletes the
`ENQUEUED <<` line* — the return pin is blind to the side effect, and the job pin
kills it. That is §7 M-11's acceptance criterion ("vacuous-return + meaningful-job
fixture → return pin `:worthless`, job pin `:strong`") satisfied by construction
rather than by hope.

**(c) `--format json` is a versioned contract.** `schema_version: "1.2"`, a
`summary` block, and `survivors[]` entries carrying `subject`, `file`, `line`,
`operator`, `id`, `token`, and a unified `diff`. Everything `PinScore` needs, plus
a diff good enough for M-12 to print.

**(d) The Ruby >= 3.4 requirement is not a blocker.** `--test-command CMD` runs
the target suite as a subprocess in the app's own runtime. Verified end to end:

```
mutineer 0.11.4 on Ruby 3.4.6, scoring a suite executing on Ruby 2.6.4
  --test-command "./run_legacy_rspec.sh %{files}"
  => 80.0%, 4/5 killed - identical to the native 3.4 run
```

This is the same split pinspec already uses in §4(a): the modern tool in its own
gemset, the app's code in the app's runtime. In a real application the command is
simply `bundle exec rspec %{files}`, which is self-contained by construction.

Note the failure mode found on the way: mutineer scrubs Ruby PATH pins, so a
command that relies on an inherited rvm environment breaks. It has to establish
its own runtime.

**(e) It refuses rather than reporting garbage.** It runs the unmutated suite
first and aborts if that is not green, naming the likely causes (failing tests,
DB, `RAILS_ENV`, migrations). The same discipline pinspec applies to itself — a
tool that scored a red suite would produce numbers that mean nothing.

## 4. Costs and limits found

- **`--test-command` forces `--jobs 1`.** No per-worker DB isolation yet, stated
  plainly by the tool. So legacy apps score **serially**: cost ≈ mutants × one
  suite boot. This is independent confirmation of the review's T3-3 point that
  `--validate` cannot live inside the `<5 min/target` budget, and §14 is right to
  exclude it.
- **`--daemon` and `--test-command` are mutually exclusive.** The daemon (boot
  once, fork per mutant, per-worker DB isolation) needs `--rails`/`--boot`, which
  means running in-process — and that requires the *app* to be on Ruby ≥ 3.4. So
  the adapter has two modes:

  | Target app Ruby | Mode | Parallel |
  |---|---|---|
  | ≥ 3.4 | `--rails --daemon` | yes |
  | < 3.4 | `--test-command "bundle exec rspec %{files}"` | no (serial) |

- **Prefer `--strategy redefine` over the default `reload`.** Whole-file reload
  re-executes the file and emits `already initialized constant` warnings on any
  class with a constant. `--rails` already implies `redefine`.
- **Equivalent mutants leak.** There is an `ignored (equivalent, suppressed)`
  bucket, but one genuinely equivalent mutant in this spike was not caught: dropping
  `.round(2)` when `100.0 * 1.08 == 108.0` exactly. `PinScorer` must treat a small
  number of false survivors as irreducible and not present the score as exact.
- **Maturity is the real risk**, not capability: 0.11.4, first release five weeks
  ago, 4,710 downloads, one maintainer. Mitigations already in the design — the
  adapter boundary isolates it (§7 M-11 "adapter-isolated"), `mutant` stays the
  opt-in alternative, and the JSON carries `schema_version` so a breaking change
  is detectable rather than silent. Pin `~> 0.11`.

## 5. Why mutineer stays the default

MIT, **zero runtime dependencies**, Prism-based. For a tool whose whole promise
is "zero gems added to a client Gemfile" (§4a), a zero-dependency MIT engine is
not merely acceptable — it is the only one of the three that fits the constraint.
mutant's license is exactly the entanglement v0.1 was right to avoid, and it
remains available for anyone who wants a mature engine and can accept the terms.

## 6. Contract changes this spike forces

1. **M-11 receives `qualified_name`, not `source_range`.** §7 M-01 hands
  `source_range` to the mutation adapter, but the backend targets a subject by
  name: `--only "InvoiceCalculator#call"`. `TargetProfile#qualified_name` already
  produces exactly that string. `source_range` stays useful for the `--since`
  line-based mode and for reports, but it is not what selects the subject.

2. **Aspect scoring requires per-aspect spec files.** `--test` takes files, not
  example filters, so `PinScorer` must write one temporary spec file per aspect
  (derived from the emitted pin file) and run the backend once per aspect. This is
  a new M-09 ↔ M-11 coupling: SpecWriter must keep one `it` per aspect, cleanly
  separable. Worth writing into §7 M-09 now rather than discovering at M5.

3. **`--validate` raises pinspec's Ruby floor from 3.2 to 3.4.** `gem install
  mutineer` fails outright on 3.2.2 (verified). pinspec's CLI floor stays 3.2, so
  mutineer must be an **optional** dependency, `--validate` must fail with a clear
  message on 3.2/3.3, and CI can only exercise the validate path on 3.4.

## 7. What remains unproven

Deliberately, because the fixture apps do not exist yet (M2–M3):

- Boot time and total wall clock on a **real Rails app**. The daemon path and the
  serial `--test-command` path both need `rails71_basic` to measure.
- Interaction with Zeitwerk eager-loading under `--strategy redefine`.
- Whether `--only` resolves a subject inside a namespaced class
  (`Billing::Reconciler.call`) and a class method as reliably as an instance
  method.

These become M3 tasks once a fixture app can boot. None of them threatens the
choice of backend; they are cost and coverage questions.
