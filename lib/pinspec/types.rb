# frozen_string_literal: true

module Pinspec
  PARAM_KINDS = %i[req opt rest keyreq key keyrest].freeze

  OPTIONAL_PARAM_KINDS   = %i[opt key rest keyrest].freeze
  POSITIONAL_PARAM_KINDS = %i[req opt rest].freeze

  CONSTRUCTION_KINDS = %i[
    new
    class_method
    interactor
    dry_initializer
    struct
    model_instance
  ].freeze

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
    :clock_sites,
    :construction_source
  ) do
    def singleton?
      construction_kind == :class_method
    end

    def needs_subject?
      !%i[class_method model_instance].include?(construction_kind)
    end

    def qualified_name
      singleton? ? "#{class_name}.#{method_name}" : "#{class_name}##{method_name}"
    end

    def clock_dependent?
      !clock_sites.empty?
    end

    def input_params
      initializer_params + params
    end
  end

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

  ImportCluster = Data.define(:model, :table, :name, :attrs, :source, :redacted, :flags) do
    def redaction_read?
      Array(flags).include?(:redaction_read)
    end
  end

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

  MULTI_DB_ROLLBACK_WARNING =
    "This app declares more than one writing database. pinspec's per-case " \
    "rollback covers the PRIMARY writing connection only - writes made through " \
    "any other connection are not rolled back, and pins that depend on them are " \
    "not trustworthy."

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

    def isolation
      case db_cleaner
      when :truncation  then :truncation
      when :transaction then :transaction
      else transactional_fixtures == false ? :truncation : :transaction
      end
    end

    def isolation_source
      case db_cleaner
      when :truncation, :transaction then "DatabaseCleaner.strategy = #{db_cleaner.inspect}"
      else "use_transactional_fixtures = #{transactional_fixtures.inspect}"
      end
    end

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

  FactoryAttribute = Data.define(:name, :kind, :source, :factory, :line) do
    def association?
      kind == :association
    end

    def transient?
      kind == :transient
    end
  end

  FactoryTrait = Data.define(:name, :attributes, :line)

  FactoryCallback = Data.define(:hook, :stage, :line) do
    def to_s
      "#{hook}(:#{stage})"
    end
  end

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

  FactoryIndex = Data.define(:factories, :legacy_dsl, :skipped) do
    def factory(name)
      wanted = name.to_sym

      factories.find { |f| f.name == wanted } ||
        factories.find { |f| f.aliases.include?(wanted) }
    end

    def for_model(model)
      factories.select { |f| f.model == model.to_s }
    end

    def dsl_module
      legacy_dsl ? "FactoryGirl" : "FactoryBot"
    end

    def traits_for(name)
      ancestry(name).flat_map(&:traits)
    end

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

  Column = Data.define(
    :name, :type, :null, :default, :limit, :precision, :scale, :array, :unknown_type, :line
  ) do
    def nullable?
      null != false
    end

    def unknown_type?
      unknown_type == true
    end

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

  ForeignKey = Data.define(:from_table, :column, :to_table, :primary_key, :on_delete, :source) do
    def heuristic?
      source == :heuristic
    end

    def key
      "#{from_table}.#{column}"
    end
  end

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

    def annotate_relevance(planned_tables)
      wanted = Array(planned_tables).map(&:to_s)

      with(skipped_statements: skipped_statements.map do |statement|
        statement.with(relevant: statement.tables_touched.any? { |t| wanted.include?(t) })
      end)
    end
  end
end
