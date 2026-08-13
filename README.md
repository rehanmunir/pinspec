# pinspec

Characterization tests for legacy Rails codebases.

Point pinspec at a Rails service object or model method. It works out how to invoke
it, runs it against your test database, writes an RSpec file that freezes what the
code does today, and then verifies that file passes in your app's own test
environment.

```bash
pinspec pin app/services/invoice_calculator.rb#call --app .
```

```
capture  InvoiceCalculator#call
  runs           2 boots
  stable         2 of 2

emitted  spec/characterization/invoice_calculator_call_spec.rb
  pinned         c001, c002
  aspects        2 return, 2 jobs

verify
  isolated       green (4 examples)
  hostile        green (4 examples)
  neighbored     green (4 examples)
```

A pin freezes current behaviour. It is not a claim that the behaviour is correct —
bugs get pinned on purpose, so a refactor cannot change them silently.

## Install

```bash
gem install pinspec
```

Ruby >= 3.2. Rails >= 6.0 in the target app. PostgreSQL, MySQL and SQLite all work:
pinspec adds no database gem, because everything that touches your data runs inside
your app through `rails runner`.

## Commands

| Command | What it does |
| --- | --- |
| `pinspec analyze [APP]` | App profile, schema, factories and hazards. Reads files only — no boot, no database. |
| `pinspec plan FILE#METHOD --app PATH` | The world it would build, and the arguments it would pass. Still no execution. |
| `pinspec capture FILE#METHOD --app PATH` | Runs the probe in your app, writes `observations.json`. |
| `pinspec pin FILE#METHOD --app PATH` | Capture, emit the spec, verify it. |
| `pinspec validate FILE#METHOD --app PATH` | Mutation-scores the pin, one aspect at a time. Needs Ruby >= 3.4 and `mutineer`. |
| `pinspec report --app PATH` | Prints the last run's markdown report. |

Useful flags: `--cases N`, `--boots N`, `--sample` (read real rows from your
development database), `--no-redact`, `--force`, `--app-env KEY=VALUE`.

The target comes first. `--app-env` is an array option and will swallow it otherwise.

## Verification

Every pin is checked in three environments, because one run on the machine that
captured it proves repeatability rather than portability:

- **isolated** — the file alone, as captured.
- **hostile** — a different timezone, locale and RSpec seed.
- **neighbored** — the file twice in one process, so accumulated state shows up.

The emitted spec forces the capture's answer on every axis rather than inheriting
the suite's: isolation regime, queue adapter, clock, seed, locale and zone. A suite
that truncates instead of transacting, or that runs jobs inline, would otherwise
turn a green capture into a red or vacuous spec.

## No database ids in a pin

Postgres sequences are not transactional, so a rolled-back case still advances them
and an id differs on the next run. A foreign key pointing at a record the plan built
becomes a ref; anything else id-shaped becomes a wildcard:

```ruby
{"t" => "record", "class" => "Invoice", "attributes" => {
  "customer_id" => {"t" => "ref", "v" => "customer_1"},
  "total"       => {"t" => "decimal", "v" => "110.0"}
}}
```

Ids also hide in job arguments (`perform_later(record.id)`) and inside GlobalID
strings (`gid://app/Invoice/22`). Both are resolved to the record they name, or keep
the model and drop the id.

## Real rows, with the personal data rewritten

`--sample` reads rows from your development database through a generated read-only
script, then rebuilds them as `create!` calls in the spec. Rewrites preserve **domain
and length** — `rehan.munir@acme.co` keeps `@acme.co` and its character count — so a
target that routes on a domain or validates a length behaves as it always did. Row
sources are hashed, so a committed spec does not map back to production rows.

`--no-redact` turns this off. It writes real personal data into a file you commit.

## It refuses rather than guessing

| Situation | Result | Exit |
| --- | --- | --- |
| target takes a block or yields | `BlockRequired` | 4 |
| constructor resolves its own dependencies, or `super`s into another file | `UnresolvableSetup(:opaque_constructor)` | 5 |
| a parameter names a model the app has no table, model or factory for | `UnresolvableSetup(:unresolvable_parameter)` | 5 |
| two tables require each other through NOT NULL foreign keys | `UnresolvableSetup(:association_cycle)` | 5 |
| a NOT NULL column whose type has no honest value | `UnresolvableSetup(:unknown_column_type)` | 5 |
| target reads an attachment | `UnresolvableSetup(:attachment)` | 5 |
| `ros-apartment` tenancy | `UnresolvableSetup(:apartment)` | 5 |
| name resolves to two definitions | `AmbiguousTarget` | 3 |
| `delegate` or `method_missing` redirect | `TargetNotFound` | 2 |
| `db/structure.sql` instead of `db/schema.rb` | `SchemaFormatUnsupported` | 6 |
| Rails below 6.0 | `UnsupportedRailsVersion` | 10 |
| no case was stable across boots | `NothingStableToPin` | 8 |

It will not pass `nil` for a model it could not build: the target would raise on nil,
and that error would be pinned as though your application produced it.

## Mutation scoring

`pinspec validate` grades each aspect of a pin separately, because they are blind to
different things — a return-value pin does not notice a deleted `perform_later`, and
a job pin does not notice the arithmetic:

```
return         66.7% weak (4 killed, 2 survived)
    survived: statement_removal at line 18 - SyncJob.perform_later(invoice.id)
jobs           50.0% weak (3 killed, 3 survived)
    survived: arithmetic at line 14 - +

nothing survived every aspect: together, the pins cover this target.
```

A pin containing a wildcard or a truncated value is never reported as strong, however
well it scores. An aspect the pin does not assert is skipped rather than scored, since
scoring an absent aspect yields a vacuous 100%.

## Known limits

- **Attachments** are refused rather than run against an empty blob.
- **`after_commit`** never fires under transactional isolation, in the capture or in
  the emitted spec. pinspec does not fake it, so this is a real divergence from
  production and the report says so.
- **Multiple writing databases**: per-case rollback covers the primary writing
  connection only.
- **Read and clock detection scans the target's own file.** A transitive callee that
  reads the current user or the process clock is invisible, so no warning is not proof
  of no read.
- **Small worlds make weak pins.** The default corpus builds the smallest world that
  can exist, which often does not reach a target's branches — mutation scores on real
  service objects are frequently weak. `--sample` helps; read the scores before
  trusting a pin.

## Development

```bash
bundle install
bundle exec rspec
LANG=C LC_ALL=C TZ=Etc/GMT+8 bundle exec rspec
```

That second run matters: pinspec's own hostile verify config sets `LANG=C`, so a
non-ASCII string literal in shipped source would break it.

Fixtures come in two kinds. Those under `spec/fixtures/targets/` and most of
`spec/fixtures/apps/` are parsed, never loaded, so they reference constants that do
not exist in this repo — that is the point, since the analyzer must work against a
repo you have not booted. Two of them are real Rails apps that boot on PostgreSQL and
cover both isolation regimes; the specs needing them skip rather than fail when they
are not prepared:

```bash
cd spec/fixtures/apps/rails71_basic && bundle install && RAILS_ENV=test bundle exec rails db:schema:load
```

`spec/equivalence/host_equivalence_spec.rb` is the one to read first. It holds the
probe process and the spec process to the same answer across all six axes they could
disagree on, and each fixture is configured to disagree with the plan so that
agreement cannot happen by accident.

## License

MIT
