# frozen_string_literal: true

require "digest"

module Pinspec
  module Setup
    # M-05. TargetProfile + AppProfile (+ hydrated import clusters from M-06) =>
    # SetupPlan. The long pole, and the module the whole design leans on: the plan
    # is what both hosts execute, so anything it fails to say is something the
    # probe and the emitted spec are free to disagree about.
    #
    # Pure data in, pure data out. Never opens a connection, never loads app code,
    # never touches the app process - a plan can be printed and read before
    # anything is run, which is what `pinspec plan --dry-run` is for.
    #
    # Rule numbering below follows spec v0.3 §7 M-05 so the two can be diffed.
    class ContextBuilder
      MAX_GENERATIONS = 3

      class << self
        def build(target:, profile:, imports: [], generation: 1, tz: nil)
          new(target: target, profile: profile, imports: imports, generation: generation, tz: tz).build
        end
      end

      def initialize(target:, profile:, imports: [], generation: 1, tz: nil)
        @target     = target
        @profile    = profile
        @imports    = imports
        @generation = generation
        @tz         = tz || Runner::Sandbox::FORCED_ENV.fetch("TZ")
        @resolver   = DependencyResolver.new(profile.schema, profile.factories)
      end

      def build
        @steps    = []
        @bindings = {}
        @notes    = []
        @counters = Hash.new(0)
        @refs     = {} # table name => ref of the first record created for it

        refuse_unsupported_tenancy!  # rule 5
        refuse_attachment_targets!   # rule 11

        environment_steps            # rule 7, 9
        record_steps                 # rules 1, 2, 3, 4, 8
        import_steps
        context_steps                # rules 5, 6, 10
        subject_step                 # rule 12

        plan
      end

      private

      # ---------------------------------------------------------------- refusals --

      # Rule 5. Apartment switches schemas per tenant; a plan built against the
      # wrong schema would create rows nobody can see and pin behaviour nobody has.
      def refuse_unsupported_tenancy!
        return unless @profile.tenancy == :apartment

        raise UnresolvableSetup.new(
          :apartment,
          "this app uses ros-apartment, which switches PostgreSQL schemas per " \
          "tenant. pinspec cannot tell which schema a target expects, and building " \
          "a world in the wrong one would pin behaviour that never happens."
        )
      end

      # Rule 11. Naming the wall beats hanging on it: an attachment needs a blob,
      # and synthesizing blobs is P1 (spec open question 7).
      def refuse_attachment_targets!
        return if @profile.attachments.empty?

        touched = attachment_findings_for_target
        return if touched.empty?

        finding = touched.first
        raise UnresolvableSetup.new(
          :attachment,
          "#{@target.class_name} carries an attachment (#{finding.kind} at " \
          "#{finding.file}:#{finding.line}) and #{@target.qualified_name} reads it. " \
          "pinspec cannot synthesize a blob, so it will not pin a target running " \
          "against an empty attachment."
        )
      end

      # Only refuse when the target's *own* class is attached AND the method body
      # mentions something attachment-shaped. A target that never touches the
      # attachment is perfectly pinnable.
      def attachment_findings_for_target
        attachment_kinds = %i[active_storage carrierwave paperclip]

        @profile.model_findings.select do |finding|
          next false unless attachment_kinds.include?(finding.kind)
          next false unless finding.model == @target.class_name

          references_attachment?
        end
      end

      def references_attachment?
        @target.referenced_constants.any? { |c| c.start_with?("ActiveStorage") } ||
          @target.method_name.to_s.match?(/attach|upload|file|blob|avatar|photo|document/)
      end

      # ------------------------------------------------------------ environment --

      # Rule 7 (always) and rule 9 (flags). These come first so that every record
      # created afterwards sees the frozen clock and the pinned locale - a
      # created_at written before the clock is frozen is a value nobody can pin.
      def environment_steps
        add(:freeze_time, at: PINSPEC_EPOCH)
        add(:seed_random, seed: PINSPEC_SEED)
        add(:set_locale, locale: @profile.default_locale)
        add(:set_zone, zone: @profile.default_zone)

        flag_steps
      end

      # Rule 9. Every flag the target names is pinned explicitly OFF, so the
      # captured branch is a decision rather than whatever the flag store held.
      def flag_steps
        return unless @profile.flags == :flipper

        referenced_flags.each do |flag|
          add(:set_flag, flag: flag, enabled: false)
        end
      end

      # Flipper.enabled?(:some_flag) inside the target. Read off referenced
      # constants plus the source the parser already collected.
      def referenced_flags
        return [] unless @target.referenced_constants.include?("Flipper")

        source = File.file?(@target.file_path) ? Analyzer::Source.read(@target.file_path) : ""
        first, last = @target.source_range
        body = source.lines[(first - 1)..(last - 1)].to_a.join

        body.scan(/Flipper\.enabled\?\(\s*:(\w+)/).flatten.map(&:to_sym).uniq
      end

      # ---------------------------------------------------------------- records --

      # Rules 1, 2, 3, 4, 8. Root records are the model-typed parameters plus, for a
      # model target, the subject itself.
      def record_steps
        roots = root_tables
        # Before the early return below, not after: a target whose parameters ALL fail
        # to resolve has no root tables, so a check that lived only in
        # `bind_parameters` never ran for it. On the real application the refusal fired
        # only by luck - `OrderCyclesList(distributor, customer)` happened to have a
        # second parameter that did resolve, which is what kept root_tables non-empty.
        @target.input_params.each do |param|
          refuse_unresolvable_model_param!(param) if table_for_param(param).nil?
        end

        return if roots.empty?

        order = @resolver.creation_order(
          roots,
          # A factory owns its own associations; walking past it would build a
          # second parent that the factory never uses.
          prune: ->(table_name) { !@resolver.factory_for(table_name).nil? }
        )

        order.each { |table_name| create_record_for(table_name) }

        bind_parameters
      end

      # Rule 1. A parameter is model-typed when its hint resolves to a real table.
      # Everything else is a scalar and belongs to M-06's boundary corpus.
      def root_tables
        tables = @target.input_params.filter_map { |param| table_for_param(param)&.name }

        if @target.construction_kind == :model_instance
          subject_table = @resolver.table_for(@target.class_name)
          tables = [subject_table.name] + tables if subject_table
        end

        tables.uniq
      end

      def table_for_param(param)
        @resolver.table_for_type_hint(param.type_hint)
      end

      # One record per model-typed *parameter*, not per table. Two Company
      # parameters are two companies: binding both to the same row would build a
      # world where a company merges with itself, which is not the world any
      # reader would have written.
      # Type hints that are not models. A parameter hinted `Hash` or `String` needs no
      # record, and passing nil for one is a perfectly ordinary boundary value.
      NON_MODEL_HINTS = %w[
        String Symbol Integer Float Numeric Decimal BigDecimal Boolean TrueClass
        FalseClass Hash Array Range Time Date DateTime Proc Class Module Object
        NilClass Params Param Options Option Attributes Attribute Id Ids Name
        Amount Quantity Count Total Price Rate Percentage Status State Kind Type
      ].freeze

      # Refuse rather than substitute nil. This is the single worst thing pinspec can
      # do, and the first real application walked straight into it: `distributor` in
      # `Shop::OrderCyclesList.new(distributor, customer)` is an Enterprise, no table
      # is called `distributors`, so pinspec passed nil, the target raised
      # NoMethodError on nil, and that got pinned - green in all three verify configs -
      # as though it were the application's behaviour. It is pinspec's behaviour.
      #
      # A pin of our own failure to build a world is worse than no pin: it is
      # authoritative-looking fiction, and a reader has no way to tell it apart from a
      # real characterization of a real bug.
      def refuse_unresolvable_model_param!(param)
        hint = param.type_hint.to_s
        return if hint.empty?
        return unless hint.match?(/\A[A-Z]/)
        return if NON_MODEL_HINTS.include?(hint)
        return unless param.default_source.nil?
        return if %i[rest keyrest block].include?(param.kind)

        # And only when nothing ELSE can type it. pinspec's typing precedence is
        # default literal, then a schema column of the same name, then the name-derived
        # hint - and the hint is the weakest tier by design. A parameter named `region`
        # hints `Region`, but if the schema has a `region` string column then the corpus
        # supplies a real string and there is no nil to refuse. Refusing there would
        # reject perfectly pinnable targets on the strength of the guess pinspec
        # already documents as its least reliable signal.
        return if unambiguous_column_for(param.name)

        raise UnresolvableSetup.new(
          :unresolvable_parameter,
          "parameter `#{param.name}` looks like a #{hint}, but no table, model or " \
          "factory in this application answers to that name, so pinspec has nothing " \
          "to pass. It will not pass nil instead: the target would raise on nil and " \
          "that error would be pinned as though the application produced it. Add a " \
          "factory named :#{underscore_word(hint)} (a declared `class:` is enough), or " \
          "pin a target whose arguments can be built."
        )
      end

      # The same rule Inputs::Corpus#column_for uses: a column of this name, and only
      # if every table agrees on its type. Two tables disagreeing means the schema is
      # telling us nothing.
      def unambiguous_column_for(name)
        matches = @profile.schema.tables.filter_map { |table| table.column(name) }
        return nil if matches.empty?

        matches.map(&:type).uniq.size == 1 ? matches.first : nil
      end

      def underscore_word(str)
        str.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      def bind_parameters
        bound = {}

        @target.input_params.each do |param|
          table = table_for_param(param)
          next if table.nil?

          @bindings[param.name] =
            if bound[table.name]
              create_record_for(table.name, additional: true)
            else
              bound[table.name] = true
              @refs[table.name]
            end
        end

        return unless @target.construction_kind == :model_instance

        subject_table = @resolver.table_for(@target.class_name)
        @bindings[:__subject__] = @refs[subject_table.name] if subject_table
      end

      # Rule 2. A factory when one exists and persists; otherwise a schema-driven
      # minimal create!. The two paths differ in how much they build:
      #
      #   factory  - one step. factory_bot builds the associations itself, which is
      #              both idiomatic and what a human would have written.
      #   schema   - the required belongs_to closure is built explicitly and wired
      #              through assoc_refs, because create! will not do it for us.
      # `additional` forces a second row for a table that already has one, and
      # returns its ref rather than recording it as *the* ref for that table.
      def create_record_for(table_name, additional: false)
        return @refs[table_name] if @refs.key?(table_name) && !additional

        table = @profile.schema.table(table_name)
        refuse_unfillable_columns!(table)

        if @resolver.self_referential_required?(table)
          raise UnresolvableSetup.new(
            :association_cycle,
            "#{table_name} has a NOT NULL foreign key to itself, so its first row " \
            "would have to exist before it is created."
          )
        end

        factory = @resolver.factory_for(table_name)
        note_declined_factory(table_name)

        ref = next_ref(table_name)
        @refs[table_name] = ref unless additional

        if factory
          add(:create_record, name: ref, factory: factory.name, model: factory.model, attrs: {}, assoc_refs: {})
        else
          add(:create_record,
              name:       ref,
              factory:    nil,
              model:      @resolver.model_for(table_name),
              attrs:      schema_attributes(table),
              assoc_refs: association_refs(table))
        end

        ref
      end

      # The refusal M-02 deferred: a NOT NULL column whose type this parser does
      # not model cannot be filled, and guessing would produce a row that is not
      # the row the app would have.
      def refuse_unfillable_columns!(table)
        return if table.nil?

        unfillable = table.required_columns.select(&:unknown_type?)
        return if unfillable.empty?

        column = unfillable.first
        raise UnresolvableSetup.new(
          :unknown_column_type,
          "#{table.name}.#{column.name} is NOT NULL with type #{column.type} " \
          "(#{table.name} is needed to build #{@target.qualified_name}), and " \
          "pinspec has no value it can honestly supply for that type."
        )
      end

      # Rule 4. Deterministic uniquifier, namespaced by plan generation so a
      # re-plan after a seed-data collision cannot collide the same way twice.
      def schema_attributes(table)
        unique = @resolver.unique_columns(table)

        @resolver.required_scalars(table).each_with_object({}) do |column, attrs|
          uniquifier = unique.include?(column.name) ? uniquifier_for(table) : nil
          value = @resolver.placeholder_for(column, frozen_time: PINSPEC_EPOCH, uniquifier: uniquifier)
          attrs[column.name] = value unless value.nil?
        end
      end

      def uniquifier_for(table)
        "p#{@generation}-#{@counters[table.name]}"
      end

      # Rule 3. Wire the explicit parents built by creation_order.
      def association_refs(table)
        @resolver.required_associations(table).each_with_object({}) do |(column, parent), refs|
          parent_ref = @refs[parent]
          refs[column] = parent_ref if parent_ref
        end
      end

      def note_declined_factory(table_name)
        declined = @resolver.declined_factory_for(table_name)
        return if declined.nil?
        return if @resolver.factory_for(table_name)

        note(:factory_declined,
             "factory :#{declined.name} never persists " \
             "(#{declined.hazards.map(&:first).join(', ')}), so #{table_name} is " \
             "built from the schema instead")
      end

      # M-06 hands over already-hydrated clusters; the plan orders them after the
      # created records so their refs can point at either.
      #
      # The cluster's own `name` is used verbatim and never re-minted: the hydrator
      # has already embedded these names inside the attrs as intra-cluster foreign
      # keys, so renaming a step here would leave those refs pointing at nothing.
      def import_steps
        @imports.each do |cluster|
          add(:import_record,
              name:     cluster.name,
              model:    cluster.model,
              attrs:    cluster.attrs,
              source:   cluster.source,
              # Carried through so the report can say WHICH attributes were
              # rewritten. "some personal data was redacted" is not an audit trail.
              redacted: cluster.redacted,
              flags:    cluster.flags)

          @refs[cluster.table] ||= cluster.name
        end
      end

      # ---------------------------------------------------------------- context --

      # Rules 5, 6, 10. Ordered after records because every one of them points at a
      # record that has to exist first.
      def context_steps
        tenant_step
        auth_step
        whodunnit_step
      end

      # Rule 5. acts_as_tenant needs the tenant set for the duration of the case.
      def tenant_step
        return unless @profile.tenancy == :acts_as_tenant

        tenant_finding = @profile.findings(:acts_as_tenant).first
        return note(:tenancy_unresolved, "acts_as_tenant is in use but no tenanted model was found") if tenant_finding.nil?

        tenant_ref = tenant_ref_for(tenant_finding)
        return note(:tenancy_unresolved,
                    "acts_as_tenant is in use but pinspec could not identify the " \
                    "tenant record for #{tenant_finding.model}") if tenant_ref.nil?

        add(:set_tenant, record_ref: tenant_ref)
      end

      # The tenant is the thing the tenanted model belongs to, so prefer a record
      # already in the plan; otherwise create one.
      def tenant_ref_for(finding)
        table = @resolver.table_for(finding.model)
        return nil if table.nil?

        tenant_tables = @resolver.required_associations(table).map(&:last)
        tenant_table  = tenant_tables.first
        return nil if tenant_table.nil?

        create_record_for(tenant_table)
      end

      # Rule 6. devise gets a stubbed current user; a CurrentAttributes app gets
      # the attribute set. pundit only ever earns a note - authorization runs
      # inside the target, and pinning what it decides is the whole point.
      def auth_step
        if %i[devise current_attributes].include?(@profile.auth) && !target_may_read_current_user?
          note(:current_user_not_built,
               "#{@profile.auth} is in use, but this target does not mention a current " \
               "user, so none is created - the smallest world that can exist is the one " \
               "least likely to surprise a reader. Honest limit: this scans the target's " \
               "own file, so a transitive callee that reads one will see nil.")
          return auth_note
        end

        case @profile.auth
        when :devise
          add(:stub_current, kind: :devise_user, record_ref: user_ref)
        when :current_attributes
          add(:stub_current, kind: :current_attributes, record_ref: user_ref)
        end

        auth_note
      end

      def auth_note
        return if @profile.authz == :none

        note(:authz_present,
             "#{@profile.authz} is in use; pinspec pins whatever it decides rather " \
             "than bypassing it")
      end

      # Whether building a user could change what this target observes. Creating one
      # unconditionally is not free: on the first real application it meant every
      # capture ran the app's `:user` factory, which is non-deterministic (FFaker
      # emails, one in three rejected by the app's own validation) - so a target that
      # never reads a user could not be pinned at all, for a reason that had nothing
      # to do with the target.
      #
      # The same file-scoped scan `referenced_flags` uses, and the same honest limit:
      # a callee that reads a current user is invisible here.
      CURRENT_USER_READS = /
        current_user | current_spree_user | spree_current_user | current_admin
        | Current\s*\. | whodunnit | PaperTrail\s*\.\s*request
      /x

      def target_may_read_current_user?
        return false unless File.file?(@target.file_path)

        Analyzer::Source.read(@target.file_path).match?(CURRENT_USER_READS)
      end

      # Rule 10. PaperTrail records who did it, and an unset whodunnit is a null
      # that changes between hosts.
      def whodunnit_step
        return unless @profile.versioning == :paper_trail

        ref = @steps.find { |step| step.kind == :stub_current }&.payload&.dig(:record_ref)

        if ref.nil?
          return note(:whodunnit_unset,
                      "paper_trail is in use but no current user was built, so versions " \
                      "this target creates record a null whodunnit. Both hosts do this, " \
                      "so the pin is consistent; it is production that differs.")
        end

        add(:set_whodunnit, record_ref: ref)
      end

      # One user record, shared by auth and whodunnit: create_record_for returns the
      # existing ref on the second call, so no memo is needed here.
      # An engine renames this table too: devise on Spree authenticates against
      # `spree_users`, so a literal list of table names finds nothing and every
      # target that reads the current user silently sees nil. The type-hint resolver
      # already knows how to cross an engine prefix, so it is asked as well - which
      # on the first real application is the difference between a plan with a signed-
      # in user and a plan whose authorization checks all run against nobody.
      def user_ref
        table = %w[users accounts people admins].find { |name| @profile.schema.table(name) } ||
                %w[User Account Person Admin].filter_map { |hint| @resolver.table_for_type_hint(hint)&.name }.first

        if table.nil?
          note(:user_table_missing,
               "no users/accounts/people table found, so the current user is left " \
               "unset; a target that reads it will see nil")
          return nil
        end

        create_record_for(table)
      end

      # ---------------------------------------------------------------- subject --

      # Rule 12. The step carries the class and how to build it; the argument
      # *values* come per-case from InputCase, because a plan is per-target and
      # cases are per-case. Putting args here would be a category error.
      def subject_step
        return unless @target.needs_subject?

        add(:construct_subject,
            class:  @target.class_name,
            kind:   @target.construction_kind,
            params: @target.initializer_params.map(&:name))
      end

      # ------------------------------------------------------------------- plan --

      def plan
        SetupPlan.new(
          steps:            @steps,
          isolation:        @profile.isolation, # rule 13
          env_fingerprint:  env_fingerprint,    # rule 14
          bindings:         @bindings,
          notes:            @notes,
          generation:       @generation,
          plan_id:          nil
        ).then { |draft| draft.with(plan_id: fingerprint(draft)) }
      end

      # `tz` is the timezone the PROBE will run under, which the sandbox forces -
      # NOT this shell's. Reading ENV["TZ"] here was wrong in three ways at once, and
      # only showed up when pinspec's own suite ran under TZ=Etc/GMT+8: the
      # fingerprint claimed a timezone the probe never used, the emitted spec's guard
      # then demanded that timezone while the verifier ran UTC (so every clock-
      # dependent pin was reported failed on any machine that is not UTC), and
      # `plan_id` - content-addressed over this hash - differed between two people
      # pinning the same target from different desks.
      def env_fingerprint
        {
          tz:         @tz,
          locale:     @profile.default_locale,
          zone:       @profile.default_zone,
          rails:      @profile.rails_version,
          ruby:       @profile.ruby_version,
          serializer: SERIALIZER_VERSION
        }
      end

      # Content-addressed, so the same target and app always produce the same id and
      # a changed plan is visibly a different plan. Stable across runs by
      # construction: nothing in here reads a clock or a random source.
      def fingerprint(draft)
        canonical = [
          @target.qualified_name,
          draft.isolation,
          draft.generation,
          draft.env_fingerprint.sort.map { |k, v| "#{k}=#{v}" }.join(","),
          draft.steps.map { |step| "#{step.kind}:#{canonical_payload(step.payload)}" }
        ].flatten.join("|")

        Digest::SHA256.hexdigest(canonical)[0, 12]
      end

      def canonical_payload(payload)
        payload.sort_by { |key, _| key.to_s }.map { |key, value| "#{key}=#{value.inspect}" }.join(",")
      end

      # --------------------------------------------------------------- plumbing --

      def add(kind, **payload)
        raise PinspecInternalError, "unknown setup step #{kind.inspect}" unless STEP_KINDS.include?(kind)

        @steps << SetupStep.new(kind: kind, payload: payload)
      end

      def next_ref(table_name)
        singular = Analyzer::Inflector.singular_candidates(table_name).first
        @counters[table_name] += 1

        "#{singular}_#{@counters[table_name]}"
      end

      # No deduplication here on purpose. The duplicate this used to guard against -
      # a missing user table reported twice - came from `user_ref` being asked once for
      # authentication and again for paper_trail's whodunnit. `whodunnit_step` now
      # reuses the ref the auth step already recorded, so the second call is gone and a
      # dedup could not be made to fire by any test. A mutation nothing can kill is
      # dead code rather than defence in depth, which is the verdict this project has
      # reached four times before.
      def note(kind, detail)
        @notes << { kind: kind, detail: detail }
        nil
      end
    end
  end
end
