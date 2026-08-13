# pinspec

Characterization-test harness for legacy Rails codebases.

Point pinspec at a Rails service object or model method and it works out how to
invoke it, executes it against your test database, and emits an idiomatic RSpec
file that freezes the current behavior - then verifies that file runs green in
your app's own test environment.

```
pinspec pin app/services/invoice_calculator.rb#call
```

Design: [`docs/spec-v0.3.md`](docs/spec-v0.3.md). The review that produced it:
[`docs/spec-review-v0.2.md`](docs/spec-review-v0.2.md). Backend decision:
[`docs/spike-m11-mutation-adapter.md`](docs/spike-m11-mutation-adapter.md).

## Status

`0.1.0`. **M0 through M4 complete, and M5's code with them.** `pin` captures,
emits and verifies a characterization spec that runs green with zero manual
edits, on two real Rails apps on live PostgreSQL - Rails 7.2 / Ruby 3.3 under the
transaction regime and Rails 6.1 / Ruby 3.1 under truncation.

Proved against a real application too: **Open Food Network** (Rails 7.2.3.2 on
Spree - 93 tables, 113 factories, 335 gems), unmodified apart from
`.ruby-version`. Six service objects pinned, three verify configurations green on
each, all six passing together under the app's own `rspec`, about 14 seconds per
target, one import cluster from real sampled rows. That run found **nine defects
no fixture had reached** - including a pin of pinspec's own inability to build a
world, dressed as the application's behaviour, and a verifier that reported
`0 examples` as green three times over. Both are fixed and guarded; the full list
is in the [changelog](CHANGELOG.md).

The one bar it did not clear is mutation strength: real service objects scored
**50% (weak)** and **16.7% (worthless)**, against a target of 60% strong. That is
a finding about pinspec, not a rounding error - a boundary-value corpus builds the
smallest world that can exist, and the smallest world does not reach the
branches.

| Verb | Status |
| --- | --- |
| `pinspec version` | works |
| `pinspec analyze [APP]` | app profile, schema, factories, and hazard warnings |
| `pinspec plan FILE#METHOD --app PATH` | renders the SetupPlan and the input cases that will run against it |
| `pinspec capture FILE#METHOD --app PATH` | runs the probe in the app, writes `observations.json` |
| `pinspec pin FILE#METHOD --app PATH` | capture, emit the spec, verify it in three configurations |
| `pinspec validate FILE#METHOD --app PATH` | scores the pin by aspect (needs Ruby >= 3.4 in pinspec's own gemset) |
| `pinspec report` | writes the client-facing `report.md` |

## What M-01 does

Resolves `FILE#METHOD` to a `TargetProfile` using a static Prism parse. It loads
no target-app code and connects to nothing, which is why defaults are recorded
as *source text* rather than as values.

```
$ pinspec plan app/services/invoice_calculator.rb#call
InvoiceCalculator#call
  file           app/services/invoice_calculator.rb:12-15
  construction   new: InvoiceCalculator.new(invoice, tax_engine: TaxEngine.new, rounding: :up)
  ctor params    invoice [Invoice], tax_engine: TaxEngine.new [TaxEngine], rounding: :up [Symbol]
  method params  (none)
  visibility     public
  constants      Invoice, TaxEngine
  clock sites    (none)
```

That zero-argument `#call` with its dependencies in the constructor is the shape
this whole tool exists for, and reading the constructor is what spec v0.2 could
not do.

Targets can be qualified when a bare name is ambiguous:

```
pinspec plan app/services/billing.rb#Reconciler#call    # instance method
pinspec plan app/services/billing.rb#Reconciler.call    # class method
```

## What M-09 and M-13 do

The thing the whole project is for:

```
$ pinspec pin app/services/status_reporter.rb#call --app .
capture  StatusReporter#call
  runs           2 boots
  stable         2 of 2

emitted  spec/characterization/status_reporter_call_spec.rb
  pinned         c001, c002
  aspects        2 return

verify
  isolated       green (2 examples)
  hostile        green (2 examples)
  neighbored     green (2 examples)
```

Three configurations, because one run on the capture machine proves
repeatability rather than portability: `:hostile` changes the timezone, the locale
and the RSpec seed; `:neighbored` runs the file twice in one process so
accumulated state shows up.

The emitted spec **forces** the capture's answer on every axis rather than
inheriting the suite's - isolation regime, queue adapter, clock, seed, locale,
zone - because a suite that truncates instead of transacting, or runs jobs inline,
would otherwise turn a green capture into a red or vacuous spec.

## What M-11 does

Scores a pin by asking a mutation backend to break the target and seeing which
aspect of the pin notices. Each aspect is scored in its own run against its own
spec file, because a single number over the whole pin hides both the blindness
and the coverage:

```
$ pinspec validate app/services/invoice_calculator.rb#call --app .
InvoiceCalculator#call
  return         66.7% (weak)   killed 2, survived 1
  jobs           50.0% (weak)   killed 1, survived 1
  skipped        error, mail (not asserted by this pin)

  no mutant survived every aspect: together, these pins cover the target
```

Those two numbers are the argument for the whole design. The return pin scored
66.7% because it slept through a deleted `perform_later`; the job pin scored 50%
because it slept through the arithmetic. Each is blind to what the other catches,
and nothing got through both - which is invisible if you pin only the return
value, as everyone does first.

A pin whose value is `{"t":"seq"}` or truncated is never reported as strong
however well it scores, because it asserts less than the score implies. An aspect
the pin does not assert is skipped rather than scored, since scoring an absent
aspect produces a vacuous 100%.

`--validate` needs Ruby >= 3.4 in pinspec's own gemset, which the backend
requires. The rest of pinspec keeps its 3.2 floor, and the app under test keeps
whatever Ruby it has - the suite runs in the app's own runtime through a generated
wrapper. Without the backend, `validate` refuses with a message naming the floor
and the install; nothing else is affected.

## What M-12 does

Writes the markdown report a client reads instead of reading the pins
(`tmp/pinspec/report.md`), organised so the caveats cannot be skipped: what was
pinned, what was refused and why, which isolation regime the reader has
inherited, every place a pin asserts less than it appears to, what was rewritten
out of imported rows, and hashed provenance.

Its first paragraph says that a pin is not a judgement that the behaviour is
correct. pinspec pins bugs on purpose - that is what characterization means - and
a reader who misses this will "fix" the pin.

## What M-10 does

Names the examples. This is the only place a language model touches the output,
and it is kept away from values structurally rather than by instruction: the
request carries a case id, an origin, an outcome *kind*, the class and method
name, and parameter *names*. No pinned value is put in, so no reply can be one
laundered back. A description is then discarded if it contains a hash rocket, a
serializer tag, `expect`, `eq(`, a three-digit number, or more than two quotes -
tested by handing it a model that ignores every instruction it was given.

`--no-llm` is the default. The deterministic namer is what runs unless asked
otherwise, and a naming service that fails is not allowed to fail a pin.

## What M-07 does

Runs a generated probe inside the target application and records what the code
actually does.

```
capture  InvoiceCalculator#call
  plan           64249d86779e (isolation transaction)
  runs           2 boots
  cases          3
  stable         3 of 3
  compared       status, return_value, error, enqueued_jobs, mail_deliveries, db_delta

  stable, and therefore pinnable:
    c001  returned record, 2 job(s)
    c002  returned record, 2 job(s)
    c003  returned record, 2 job(s)
```

The probe is generated (so it can be read before it runs), stdlib-only (so
nothing is added to a client's Gemfile), and held to a Ruby 2.6 syntax floor (so
it runs in the app's Ruby, not pinspec's). Every case is wrapped in a transaction
and rolled back; the rollback is proved by row count in the integration spec.

**No id ever reaches a snapshot.** Sequences are not transactional, so a
rolled-back case still advances them and a pinned id differs on the next run. A
foreign key pointing at a record the plan built becomes a ref, and everything
else id-shaped becomes `{"t":"seq"}`:

```json
{"t": "record", "class": "Invoice", "attributes": {
  "customer_id": {"t": "ref", "v": "customer_1"},
  "total":       {"t": "decimal", "v": "110.0"}
}}
```

Ids hide in two more places, both found by running against a real app: a bare
`perform_later(record.id)` in job arguments, and a GlobalID string
(`gid://app/Invoice/22`) from `deliver_later`. Both are resolved to the record
they name, or keep the model name and refuse the id.

## What M-06 does

Generates the arguments pinspec will actually invoke the target with, and shapes
real rows into something both hosts can rebuild.

```
input cases  5 (1 defaults, 4 boundary)
  c001 (defaults) new(invoice_1, tax_rate: 0.08).call
  c002 (boundary) new(invoice_1, tax_rate: 0.0).call
  c003 (boundary) new(invoice_1, tax_rate: 1.0).call
  c004 (boundary) new(invoice_1, tax_rate: -1.0).call
  c005 (boundary) new(invoice_1).call
```

One all-defaults case first, then one parameter varied per case, interleaved
across the constructor and the method so a small budget reaches both. `c005`
omits the argument entirely, which runs the method's own default expression. A
model-typed parameter is always the plan's ref, never an id.

Redaction is **domain- and length-preserving**: `rehan.munir@acme.co` keeps
`@acme.co` and keeps its length, a phone number keeps every separator. That is
the whole difference from a naive redactor - a target that routes on the domain
or validates on length observes the same behaviour it always did. When the target
actually reads a rewritten attribute, the cluster is flagged and the reason
recorded.

Sampled rows are hydrated at plan time: primary keys dropped, foreign keys
rewritten to refs, provenance hashed. The sampler itself is a generated
read-only script that runs in the app's own runtime, so pinspec needs no database
gem and works on any adapter.

## What M-05 does

Turns a target and an app profile into a **SetupPlan**: the ordered list of steps
that builds the world the target runs in. Both hosts execute this same plan, so
anything it fails to say is something the probe and the emitted spec are free to
disagree about.

```
$ pinspec plan --app . app/services/contract_reviewer.rb#call
setup plan  dea5744a1e6c (generation 1, isolation truncation)
   1. freeze_time 2026-01-01T12:00:00Z
   2. seed_random 42
   3. set_locale :de
   4. set_zone "UTC"
   5. create_record company_1 <- Company.create!
   6. create_record contract_1 <- Contract.create! company_id=>company_1
   7. set_tenant company_1
   8. create_record person_1 <- Person.create!
   9. stub_current devise_user person_1
  10. set_whodunnit person_1
  11. construct_subject ContractReviewer (new)

  parameter bindings:
    contract -> contract_1
```

The plan is pure data - no connection, no app code, no app process - so it can be
read before anything is run. `plan_id` is content-addressed, so the same target
always yields the same plan and a changed plan is visibly a different one.

It refuses rather than guessing: `ros-apartment` tenancy, a NOT NULL column whose
type has no honest value, two tables that require each other, and a NOT NULL
foreign key to a table's own row.

## What M-04 does

Profiles the app and aggregates the other readers, so `analyze` is one call and
one report:

```
app
  rails          7.1.3
  ruby           3.3.0
  isolation      truncation (DatabaseCleaner.strategy = :truncation)
  locale / zone  :de / "UTC"
  auth / authz   devise / cancancan
  tenancy        acts_as_tenant
  soft delete    paranoia
  versioning     paper_trail
  feature flags  flipper
  attachments    active_storage, carrierwave
  multi-database true
  test stack     rspec + webmock + vcr + database_cleaner
  queue adapter  :inline

  model hazards:
    default_scope: Order (app/models/order.rb:7)
    after_commit: Order (app/models/order.rb:9), Order (app/models/order.rb:10)

warnings
  1. This app declares more than one writing database. pinspec's per-case
     rollback covers the PRIMARY writing connection only - writes made through
     any other connection are not rolled back, and pins that depend on them are
     not trustworthy.
  2. This suite does not wrap examples in a transaction (DatabaseCleaner.strategy
     = :truncation), so after_commit callbacks DO fire...
```

`isolation` is the field that matters most later: it is the regime the probe and
the emitted spec must both run under. DatabaseCleaner's strategy outranks
`use_transactional_fixtures`, because the canonical DatabaseCleaner setup turns
the Rails wrapper off *so that* DatabaseCleaner can wrap instead - reading the
Rails flag alone would call that suite untransacted and make the two hosts
disagree about whether `after_commit` fires.

Below Rails 6.0 it refuses at `analyze` time (exit 10) naming the APIs it needs,
rather than failing later at the first `insert_all`.

## What M-02 does

Parses `db/schema.rb` into a `SchemaGraph`: tables, columns, indexes, and the
`fk_map` the probe uses to tell a foreign key from a quantity.

```
$ pinspec analyze .
schema
  tables         6
  columns        27
  foreign keys   5 (1 inferred)
  hazards        6

  inferred from a column name (no constraint declares these):
    orders.person_id -> people

  hazards (relevance is decided once a plan exists, in M-05):
    create_enum (order_status) at db/schema.rb:5
    unknown_column_type (orders.service_area) at db/schema.rb:36
    create_view (active_orders) on orders at db/schema.rb:66
```

Foreign keys carry provenance, because the three tiers do not deserve equal
trust: `:foreign_key` (a database constraint), `:references` (a declared
association), `:heuristic` (a `*_id` column whose stem matches a real table). A
constraint always wins over a guess, and the guesses are listed separately.

Association targets are resolved by checking the schema's real table names
rather than by pluralizing and hoping - `add_foreign_key "line_items",
"invoices"` finds `invoice_id`, not `invoic_id`. Polymorphic ids get no entry at
all: their target is whatever `_type` holds at runtime, so there is no single
table to rewrite an id into.

## What M-03 does

Indexes factory_bot / factory_girl definitions - structure only, never executed.
A factory body is arbitrary Ruby against the app's models, so booting the app to
evaluate one would mean writing rows before a plan exists. What matters is
*which* attributes and associations a factory supplies, and that is in the source.

```
factories (FactoryBot)
  factories      10
  traits         2
  unreadable     none

  callbacks fire while the plan builds records, so the probe attributes
  them to setup rather than to the target:
    invoice: after(:create) (spec/factories/invoices.rb:25)

  these factories never persist a row, so a plan cannot build on them:
    report_stub: skip_create, initialize_with
```

Inheritance is resolved across both nesting and `parent:`, in a second pass,
because `parent: :invoice` may name a factory declared in a later file. A
`factory :paid_invoice` under `factory :invoice` is an `Invoice`, not a
`PaidInvoice`. An unparsable factory file is reported rather than dropped -
silence would make the planner decide the factory does not exist.

### It refuses rather than guessing

| Situation | Result | Exit |
| --- | --- | --- |
| `yield` or an `&block` parameter | `BlockRequired` | 4 |
| constructor calls `super(...)` into another file | `UnresolvableSetup(:opaque_constructor)` | 5 |
| constructor resolves its own dependency from a container or `Rails.application.config` | `UnresolvableSetup(:opaque_constructor)` | 5 |
| name resolves to two definitions | `AmbiguousTarget` (both listed) | 3 |
| `delegate :call, to: :engine` | `TargetNotFound` naming the delegation | 2 |
| `method_missing` present | `TargetNotFound` saying so | 2 |

A dependency injected as a *parameter default* is accepted, because pinspec
passes its own value and the default never runs.

## Development

Requires Ruby >= 3.2 (`Data.define`, prism). `--validate` additionally needs 3.4,
which is the mutation backend's floor and not pinspec's.

```bash
bundle install
bundle exec rspec
LANG=C LC_ALL=C TZ=Etc/GMT+8 bundle exec rspec   # what someone else's CI looks like
```

That second run is not decoration. pinspec's own verification matrix runs under a
hostile locale, so a non-ASCII string literal anywhere in the shipped source
breaks it - guarded by `spec/ascii_output_spec.rb`, which parses pinspec with
Prism rather than grepping it.

Two kinds of fixture, for two different reasons:

- `spec/fixtures/targets/` is parsed, never loaded, so it references constants
  (`ApplicationRecord`, `Interactor`, `Dry::Initializer`) that do not exist in
  this repo. That is the point: M-01 must work against a repo you have not booted.
- `spec/fixtures/apps/` holds two Rails applications that really boot, on live
  PostgreSQL, on two different Rubies. The integration and equivalence specs skip
  rather than fail when these have not been prepared:

```bash
cd spec/fixtures/apps/rails71_basic && bundle install && RAILS_ENV=test bundle exec rails db:schema:load
cd spec/fixtures/apps/rails61_legacy && bundle install && RAILS_ENV=test bundle exec rails db:schema:load
```

`spec/equivalence/host_equivalence_spec.rb` is the one to read first: it holds the
probe host and the spec host to the same answer across all six contract axes, and
each fixture is deliberately configured to *disagree* with the plan so that
agreement cannot happen by luck.

## License

MIT
