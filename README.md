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
[`docs/spec-review-v0.2.md`](docs/spec-review-v0.2.md).

## Status

Pre-alpha. **All four M1 analyzer modules (M-01 to M-04).** Nothing executes
target-app code yet - `analyze` and `plan` read source, not a running app.

| Verb | Status |
| --- | --- |
| `pinspec version` | works |
| `pinspec plan FILE#METHOD` | resolves the target and prints its profile; SetupPlan generation lands in M2 |
| `pinspec analyze [APP]` | complete: app profile, schema, factories, and hazard warnings |
| `pinspec capture` | M3 |
| `pinspec pin` | M4 |
| `pinspec validate` / `report` | M5 |

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

Requires Ruby >= 3.2 (`Data.define`, prism).

```bash
bundle install
bundle exec rspec
LANG=C LC_ALL=C bundle exec rspec   # what someone else's CI looks like
```

Fixture targets under `spec/fixtures/targets/` are parsed, never loaded, so they
reference constants (`ApplicationRecord`, `Interactor`, `Dry::Initializer`) that
do not exist in this repo. That is the point: M-01 must work against a repo you
have not booted.

## License

MIT
