# frozen_string_literal: true

module Pinspec
  # Immutable value objects crossing module boundaries inside the CLI.
  # Spec v0.3 §6. Anything that also crosses the JSON boundary to the probe
  # degrades to plain hashes there; these types never leave this process.

  # Parameter kinds:
  #   :req      positional required            (a)
  #   :opt      positional with a default      (a = 1)
  #   :rest     positional splat               (*a)
  #   :keyreq   required keyword               (a:)
  #   :key      keyword with a default         (a: 1)
  #   :keyrest  keyword splat                  (**a)
  #
  # Spec §6 lists five; :keyrest is a sixth, because v0.2 promised to accept
  # `**rest` and gave it no kind to be recorded as. Block parameters are
  # deliberately absent — they set TargetProfile#takes_block and end the run.
  PARAM_KINDS = %i[req opt rest keyreq key keyrest].freeze

  OPTIONAL_PARAM_KINDS   = %i[opt key rest keyrest].freeze
  POSITIONAL_PARAM_KINDS = %i[req opt rest].freeze

  # How both hosts build the subject before invoking the target. This is the
  # field v0.2 lacked entirely, which made its own headline example unreachable
  # (spec v0.3 §0, breaking change 1).
  CONSTRUCTION_KINDS = %i[
    new
    class_method
    interactor
    dry_initializer
    struct
    model_instance
  ].freeze

  # default_source is the *source text* of the default, never an evaluated value —
  # M-01 loads no target-app code.
  #
  # type_hint is a guess from the parameter name and is never trusted without a
  # fallback: M-05 checks it against the schema and factory index before use.
  Param = Data.define(:name, :kind, :default_source, :type_hint) do
    def positional?
      POSITIONAL_PARAM_KINDS.include?(kind)
    end

    def optional?
      OPTIONAL_PARAM_KINDS.include?(kind)
    end

    def to_s
      case kind
      when :req     then name.to_s
      when :opt     then "#{name} = #{default_source}"
      when :rest    then "*#{name}"
      when :keyreq  then "#{name}:"
      when :key     then "#{name}: #{default_source}"
      when :keyrest then "**#{name}"
      end
    end
  end

  # A call site reading the *process* clock rather than the app clock.
  # `Time.zone.now` and `Time.current` are absent by design: they honour the
  # plan's :set_zone step. These do not, which makes their drift invisible to
  # StabilityFilter and to an isolated M-13 run — both share a machine with the
  # capture (spec v0.3 §7 M-01, §4c zone axis).
  ClockSite = Data.define(:call, :line)

  TargetProfile = Data.define(
    :file_path,
    :class_name,
    :method_name,
    :params,
    :initializer_params,
    :construction_kind,
    :visibility,
    :takes_block,
    :source_range,
    :referenced_constants,
    :clock_sites
  ) do
    def singleton?
      construction_kind == :class_method
    end

    # True when a subject must exist before the target can be invoked — i.e. when
    # the plan needs a :construct_subject step (spec v0.3 §7 M-05.12).
    def needs_subject?
      !%i[class_method model_instance].include?(construction_kind)
    end

    def qualified_name
      singleton? ? "#{class_name}.#{method_name}" : "#{class_name}##{method_name}"
    end

    def clock_dependent?
      !clock_sites.empty?
    end

    # Every input the corpus has to generate, in invocation order: constructor
    # first. M-06 allocates its --cases budget across this whole list, not just
    # the method's own params (spec v0.3 §7 M-06).
    def input_params
      initializer_params + params
    end
  end

  # -------------------------------------------------------------- M-06 inputs --

  # Every value in these four collections is serializer-v3 tagged (see Tags), and
  # a model-typed argument is a {"t":"ref"} rather than anything id-shaped.
  #
  # origin:
  #   :defaults    every parameter at its declared default - always case one
  #   :boundary    one parameter varied, the rest at defaults (OFAT)
  #   :sampled     built from a real row
  #   :stratified  one row per distinct status/state value
  InputCase = Data.define(:id, :ctor_args, :ctor_kwargs, :args, :kwargs, :origin) do
    def signature
      [ctor_args, ctor_kwargs, args, kwargs]
    end

    def to_s
      ctor = render(ctor_args, ctor_kwargs)
      meth = render(args, kwargs)

      receiver = ctor_args.empty? && ctor_kwargs.empty? ? "" : "new(#{ctor})."
      invocation = meth.empty? ? "call" : "call(#{meth})"

      "#{id} (#{origin}) #{receiver}#{invocation}"
    end

    private

    def render(positional, keyword)
      (Array(positional).map { |v| Tags.describe(v) } +
        Hash(keyword).map { |name, v| "#{name}: #{Tags.describe(v)}" }).join(", ")
    end
  end

  InputCorpus = Data.define(:cases, :setup_plan) do
    def size
      cases.size
    end

    def origins
      cases.group_by(&:origin).transform_values(&:size)
    end
  end

  # A sampled row plus the belongs_to closure it cannot exist without, hydrated at
  # plan time into attribute hashes. The probe never opens the sample connection:
  # it replays these as :import_record steps, which is what makes a snapshot
  # portable to the emitted spec (spec v0.3 §0, breaking change 1 of v0.2).
  #
  # `redacted` names the attributes that were rewritten, and `flags` carries
  # :redaction_read when the target reads one of them - a rewritten value the
  # target inspects is a pin of behaviour that never happens.
  ImportCluster = Data.define(:model, :table, :name, :attrs, :source, :redacted, :flags) do
    def redaction_read?
      Array(flags).include?(:redaction_read)
    end
  end

  # ---------------------------------------------------------------- M-05 plan --

  # A frozen instant, not "now". Both hosts travel to exactly this, so anything
  # derived from the clock is identical in the probe and in the emitted spec.
  PINSPEC_EPOCH = "2026-01-01T12:00:00Z"
  PINSPEC_SEED  = 42

  STEP_KINDS = %i[
    freeze_time seed_random set_locale set_zone set_flag
    create_record import_record
    set_tenant stub_current set_whodunnit
    construct_subject
  ].freeze

  SetupStep = Data.define(:kind, :payload) do
    def ref
      payload[:name]
    end

    def to_s
      case kind
      when :freeze_time       then "freeze_time #{payload[:at]}"
      when :seed_random       then "seed_random #{payload[:seed]}"
      when :set_locale        then "set_locale #{payload[:locale].inspect}"
      when :set_zone          then "set_zone #{payload[:zone].inspect}"
      when :set_flag          then "set_flag #{payload[:flag].inspect} = #{payload[:enabled]}"
      when :create_record     then "create_record #{payload[:name]} <- #{create_source}"
      when :import_record     then "import_record #{payload[:name]} <- #{payload[:source]}"
      when :set_tenant        then "set_tenant #{payload[:record_ref]}"
      when :stub_current      then "stub_current #{payload[:kind]} #{payload[:record_ref]}"
      when :set_whodunnit     then "set_whodunnit #{payload[:record_ref]}"
      when :construct_subject then "construct_subject #{payload[:class]} (#{payload[:kind]})"
      end
    end

    private

    def create_source
      base = payload[:factory] ? "factory(:#{payload[:factory]})" : "#{payload[:model]}.create!"
      refs = payload[:assoc_refs]
      refs.nil? || refs.empty? ? base : "#{base} #{refs.map { |c, r| "#{c}=>#{r}" }.join(', ')}"
    end
  end

  # `bindings` maps a parameter name to the ref that satisfies it. Spec §6 lists
  # four fields; this is a fifth, and it is the contract between M-05 and M-06:
  # without it, the corpus builder and the probe would each have to re-derive
  # which record satisfies which argument, and re-derivation is how two sides
  # drift apart.
  #
  # `notes` records decisions a reader would otherwise have to reverse-engineer -
  # a polymorphic type that was chosen, a factory that was declined.
  SetupPlan = Data.define(
    :steps, :isolation, :env_fingerprint, :bindings, :notes, :generation, :plan_id
  ) do
    def steps_of(kind)
      steps.select { |step| step.kind == kind }
    end

    def refs
      steps.filter_map(&:ref)
    end

    def record_steps
      steps.select { |step| %i[create_record import_record].include?(step.kind) }
    end

    def subject_step
      steps.find { |step| step.kind == :construct_subject }
    end

    def binding_for(param_name)
      bindings[param_name.to_sym]
    end
  end

  # --------------------------------------------------------------- M-04 app --

  # Spec v0.3 §12.7, quoted verbatim by `analyze` and by every report, because a
  # rollback that silently covers only one of several databases is exactly the
  # kind of safety claim that has to be stated rather than assumed.
  MULTI_DB_ROLLBACK_WARNING =
    "This app declares more than one writing database. pinspec's per-case " \
    "rollback covers the PRIMARY writing connection only - writes made through " \
    "any other connection are not rolled back, and pins that depend on them are " \
    "not trustworthy."

  # A macro or superclass found by scanning app/models. `kind` is what it means to
  # pinspec, not what it was called: after_create_commit and after_save_commit are
  # both :after_commit.
  ModelFinding = Data.define(:kind, :model, :file, :line) do
    def to_s
      "#{model} #{kind} at #{file}:#{line}"
    end
  end

  TestStack = Data.define(:framework, :webmock, :vcr, :snapshot_backends, :database_cleaner_gem) do
    def stubs_http?
      webmock || vcr
    end
  end

  # `model_findings` replaces §6's `after_commit_models` field: one uniform list
  # for every model-level discovery, with `after_commit_models` kept as a derived
  # reader so the spec's name still works. `notes` records what could not be read
  # at all - a missing Gemfile.lock turns every gem answer into a guess, and that
  # has to be visible rather than reported as "nothing found".
  AppProfile = Data.define(
    :rails_version, :ruby_version, :rails_floor_ok,
    :auth, :authz, :tenancy, :soft_delete, :versioning, :flags, :attachments,
    :multi_db, :spring,
    :model_findings,
    :default_locale, :default_zone,
    :db_cleaner, :transactional_fixtures, :queue_adapter_in_tests,
    :test_stack, :schema, :factories,
    :notes
  ) do
    def findings(kind)
      model_findings.select { |f| f.kind == kind }
    end

    def after_commit_models
      findings(:after_commit)
    end

    def rails_floor_ok?
      rails_floor_ok == true
    end

    # The regime BOTH hosts must share (spec v0.3 §7 M-05.13). v0.2 detected this
    # and used it only for post-hoc diagnosis, which is how it came to claim
    # after_commit was "suppressed consistently" when it was not.
    #
    # DatabaseCleaner's strategy outranks use_transactional_fixtures, because the
    # canonical DatabaseCleaner setup is `use_transactional_fixtures = false` with
    # `strategy = :transaction`: Rails' own wrapper is turned off precisely so
    # DatabaseCleaner can wrap instead. Reading the Rails flag alone would call
    # that suite untransacted and diverge the two hosts.
    def isolation
      case db_cleaner
      when :truncation  then :truncation
      when :transaction then :transaction
      else transactional_fixtures == false ? :truncation : :transaction
      end
    end

    # Which signal decided, so a report can say why rather than just what.
    def isolation_source
      case db_cleaner
      when :truncation, :transaction then "DatabaseCleaner.strategy = #{db_cleaner.inspect}"
      else "use_transactional_fixtures = #{transactional_fixtures.inspect}"
      end
    end

    # Every hazard worth saying out loud before anyone runs `pin`. This is the
    # pre-engagement value of `analyze` on its own.
    def warnings
      [
        multi_db_warning,
        floor_warning,
        isolation_warning,
        queue_adapter_warning,
        apartment_warning,
        default_scope_warning,
        attachment_warning,
        spring_warning
      ].compact
    end

    private

    def multi_db_warning
      MULTI_DB_ROLLBACK_WARNING if multi_db
    end

    def floor_warning
      return if rails_floor_ok

      if rails_version.nil?
        "No Gemfile.lock was read, so gem detection is unavailable and the Rails " \
          "version could not be checked against the 6.0 floor."
      end
    end

    def isolation_warning
      if isolation == :truncation
        "This suite does not wrap examples in a transaction " \
          "(#{isolation_source}), so after_commit callbacks DO fire. pinspec will " \
          "run the probe under the same regime and the capture will mutate the " \
          "test database."
      elsif !after_commit_models.empty?
        "#{after_commit_models.size} model(s) use after_commit. Under " \
          "transactional isolation these never fire in the probe or in the " \
          "emitted spec, and pinspec will not fake them - the divergence from " \
          "production is real and documented."
      end
    end

    def queue_adapter_warning
      return if queue_adapter_in_tests.nil? || queue_adapter_in_tests == :test

      "The suite sets ActiveJob's queue adapter to #{queue_adapter_in_tests.inspect}, " \
        "which executes jobs instead of enqueuing them. Emitted specs force :test " \
        "so that job pins can see anything at all."
    end

    def apartment_warning
      "ros-apartment tenancy is not supported; targets on tenanted models will " \
        "be refused rather than run against the wrong schema." if tenancy == :apartment
    end

    def default_scope_warning
      suspects = findings(:default_scope)
      return if suspects.empty?

      "#{suspects.size} model(s) declare default_scope " \
        "(#{suspects.map(&:model).uniq.join(', ')}); records a plan creates may be " \
        "invisible to the target, which reads as a bug in the target."
    end

    def attachment_warning
      return if attachments.empty?

      "Attachments present (#{attachments.join(', ')}). pinspec cannot synthesize " \
        "blobs, so a target that reads an attachment is refused rather than run " \
        "against an empty one."
    end

    def spring_warning
      "Spring is bundled; the sandbox exports DISABLE_SPRING=1 so a stale " \
        "preloader cannot serve yesterday's code." if spring
    end
  end

  # ----------------------------------------------------------- M-03 factories --

  # kind:
  #   :static       legacy factory_girl `total 100.0` - the literal is in `source`
  #   :block        `total { 100.0 }` - `source` is the block body text
  #   :association  `customer` or `association :customer, factory: :premium`
  #   :sequence     `sequence(:number) { |n| "INV-#{n}" }`
  #   :transient    declared inside `transient do ... end`; not a column
  #
  # `source` is always source text. Factories are parsed, never executed, so a
  # block's value is unknowable here - which is the point: M-05 needs to know
  # *that* a factory supplies an attribute, not what it will evaluate to.
  FactoryAttribute = Data.define(:name, :kind, :source, :factory, :line) do
    def association?
      kind == :association
    end

    def transient?
      kind == :transient
    end
  end

  FactoryTrait = Data.define(:name, :attributes, :line)

  # `after(:create)` in a factory fires during setup, so it is the reason the
  # probe clears its side-effect sinks after setup and before invoking the target
  # (spec v0.3 §7 M-07). Recording callbacks is how that noise gets attributed.
  FactoryCallback = Data.define(:hook, :stage, :line) do
    def to_s
      "#{hook}(:#{stage})"
    end
  end

  # `hazards` are DSL calls that change whether a usable row exists at all:
  # `skip_create` means the factory never persists, `initialize_with` and
  # `to_create` replace construction. A plan built on one of those would create
  # nothing and fail confusingly later.
  Factory = Data.define(
    :name, :model, :parent, :aliases, :attributes, :traits, :callbacks, :hazards, :file, :line
  ) do
    def attribute(name)
      attributes.find { |a| a.name == name.to_sym }
    end

    def trait(name)
      traits.find { |t| t.name == name.to_sym }
    end

    def associations
      attributes.select(&:association?)
    end

    def persists?
      !hazards.map(&:first).include?(:skip_create)
    end

    def fires_callbacks?
      !callbacks.empty?
    end
  end

  # (Spec §6 lists two fields; `skipped` is a third. A factory file pinspec could
  # not read means M-05 may believe a factory does not exist, and silently
  # returning fewer factories is exactly the "reads as covered everything"
  # failure the spec warns about.)
  FactoryIndex = Data.define(:factories, :legacy_dsl, :skipped) do
    def factory(name)
      wanted = name.to_sym

      factories.find { |f| f.name == wanted } ||
        factories.find { |f| f.aliases.include?(wanted) }
    end

    def for_model(model)
      factories.select { |f| f.model == model.to_s }
    end

    # What the emitted spec calls. Legacy apps predate the rename and this is the
    # whole reason legacy_dsl exists (spec v0.3 §7 M-03).
    def dsl_module
      legacy_dsl ? "FactoryGirl" : "FactoryBot"
    end

    def traits_for(name)
      ancestry(name).flat_map(&:traits)
    end

    # Every factory from the root of the parent chain down to this one. A nested
    # or `parent:`-linked factory inherits its ancestors' attributes, so M-05
    # cannot ask "does this factory supply customer_id" without walking it.
    def ancestry(name)
      chain = []
      seen  = []
      current = factory(name)

      while current && !seen.include?(current.name)
        seen << current.name
        chain.unshift(current)
        current = current.parent && factory(current.parent)
      end

      chain
    end

    # Merged attributes, ancestors first so a child overrides. Traits are applied
    # last, in the order given.
    def attributes_for(name, traits: [])
      chain = ancestry(name)
      merged = {}

      chain.each { |f| f.attributes.each { |a| merged[a.name] = a } }

      Array(traits).each do |trait_name|
        found = chain.reverse.filter_map { |f| f.trait(trait_name) }.first
        found&.attributes&.each { |a| merged[a.name] = a }
      end

      merged.values
    end
  end

  # -------------------------------------------------------------- M-02 schema --

  # `type` is the schema DSL type as written (:string, :bigint, :jsonb...).
  # `unknown_type` marks a type this parser does not model — a PostGIS
  # `st_point`, a custom domain. The column still exists and is still recorded;
  # what happens next is a *plan-time* decision (spec v0.3 §7 M-02): nullable
  # unknown columns get skipped, NOT NULL ones raise
  # UnresolvableSetup(:unknown_column_type) once a plan needs that table.
  Column = Data.define(
    :name, :type, :null, :default, :limit, :precision, :scale, :array, :unknown_type, :line
  ) do
    def nullable?
      null != false
    end

    def unknown_type?
      unknown_type == true
    end

    # A column pinspec must supply a value for before a row can be inserted.
    def required?
      !nullable? && default.nil?
    end
  end

  Index = Data.define(:columns, :name, :unique, :where) do
    def unique?
      unique == true
    end

    def partial?
      !where.nil?
    end
  end

  # primary_key is a String, an Array of Strings (composite), or nil (id: false
  # with no replacement). id_type is the declared `id:` option, defaulting to
  # :bigint — the Rails version that would settle pre-5.1 integer ids comes from
  # Gemfile.lock in M-04, which is more reliable than guessing from a dump.
  Table = Data.define(:name, :primary_key, :id_type, :columns, :indexes) do
    def column(name)
      columns.find { |c| c.name == name.to_s }
    end

    def unique_indexes
      indexes.select(&:unique?)
    end

    def required_columns
      columns.reject { |c| Array(primary_key).include?(c.name) }.select(&:required?)
    end
  end

  # source records *why* we believe this is a foreign key, because the three
  # tiers do not deserve equal trust:
  #   :references      t.references / t.belongs_to — an explicit association
  #   :foreign_key     add_foreign_key — a database-level constraint
  #   :heuristic       a *_id column whose stem matches a known table
  # Spec v0.3 §7 M-02 requires the heuristic tier be flagged, and this is where.
  ForeignKey = Data.define(:from_table, :column, :to_table, :primary_key, :on_delete, :source) do
    def heuristic?
      source == :heuristic
    end

    def key
      "#{from_table}.#{column}"
    end
  end

  # `relevant` is nil at parse time and cannot be otherwise: relevance means
  # "touches a table the plan fills", and there is no plan yet. M-05 fills it in
  # via SchemaGraph#annotate_relevance. Surfacing every skipped statement
  # unconditionally is how a warning becomes something everyone ignores.
  #
  # `references` matters for views and functions: `create_view "active_orders"`
  # has its own name in `table`, while the hazard is the orders table inside its
  # SQL body. Without this, a view sitting directly on a table the plan builds
  # would read as irrelevant.
  SkippedStatement = Data.define(:kind, :table, :column, :references, :file, :line, :relevant) do
    def relevant?
      relevant == true
    end

    def tables_touched
      ([table] + Array(references)).compact.uniq
    end

    def to_s
      subject = column ? "#{table}.#{column}" : table
      via = Array(references).empty? ? "" : " on #{Array(references).join(', ')}"
      "#{kind}#{subject ? " (#{subject})" : ""}#{via} at #{file}:#{line}"
    end
  end

  # fk_map is the wire format the probe receives in cases.json: a plain
  # {"table.column" => "target_table"} map with no provenance, because the probe
  # only needs to know *whether* an integer is a foreign key. foreign_keys keeps
  # the provenance for the report and for M-05's association walk.
  #
  # (Spec §6 lists three fields; foreign_keys is a fourth, because "heuristic
  # entries flagged" needs somewhere to live while fk_map stays plain.)
  SchemaGraph = Data.define(:tables, :fk_map, :foreign_keys, :skipped_statements) do
    def table(name)
      tables.find { |t| t.name == name.to_s }
    end

    def table_names
      tables.map(&:name)
    end

    def fk_for(table_name, column_name)
      foreign_keys.find { |fk| fk.from_table == table_name.to_s && fk.column == column_name.to_s }
    end

    def foreign_keys_from(table_name)
      foreign_keys.select { |fk| fk.from_table == table_name.to_s }
    end

    def unknown_columns
      tables.flat_map { |t| t.columns.select(&:unknown_type?).map { |c| [t.name, c] } }
    end

    # M-05 calls this once it knows which tables the plan fills, so the report can
    # separate "a view exists somewhere" from "a view sits on a table we build".
    def annotate_relevance(planned_tables)
      wanted = Array(planned_tables).map(&:to_s)

      with(skipped_statements: skipped_statements.map do |statement|
        statement.with(relevant: statement.tables_touched.any? { |t| wanted.include?(t) })
      end)
    end
  end
end
