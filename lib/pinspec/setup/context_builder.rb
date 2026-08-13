# frozen_string_literal: true

require "digest"

module Pinspec
  module Setup
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
        @refs     = {}

        refuse_unsupported_tenancy!
        refuse_attachment_targets!

        environment_steps
        record_steps
        import_steps
        context_steps
        subject_step

        plan
      end

      private

      def refuse_unsupported_tenancy!
        return unless @profile.tenancy == :apartment

        raise UnresolvableSetup.new(
          :apartment,
          "this app uses ros-apartment, which switches PostgreSQL schemas per " \
          "tenant. pinspec cannot tell which schema a target expects, and building " \
          "a world in the wrong one would pin behaviour that never happens."
        )
      end

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

      def environment_steps
        add(:freeze_time, at: PINSPEC_EPOCH)
        add(:seed_random, seed: PINSPEC_SEED)
        add(:set_locale, locale: @profile.default_locale)
        add(:set_zone, zone: @profile.default_zone)

        flag_steps
      end

      def flag_steps
        return unless @profile.flags == :flipper

        referenced_flags.each do |flag|
          add(:set_flag, flag: flag, enabled: false)
        end
      end

      def referenced_flags
        return [] unless @target.referenced_constants.include?("Flipper")

        source = File.file?(@target.file_path) ? Analyzer::Source.read(@target.file_path) : ""
        first, last = @target.source_range
        body = source.lines[(first - 1)..(last - 1)].to_a.join

        body.scan(/Flipper\.enabled\?\(\s*:(\w+)/).flatten.map(&:to_sym).uniq
      end

      def record_steps
        roots = root_tables
        @target.input_params.each do |param|
          refuse_unresolvable_model_param!(param) if table_for_param(param).nil?
        end

        return if roots.empty?

        order = @resolver.creation_order(
          roots,
          prune: ->(table_name) { !@resolver.factory_for(table_name).nil? }
        )

        order.each { |table_name| create_record_for(table_name) }

        bind_parameters
      end

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

      NON_MODEL_HINTS = %w[
        String Symbol Integer Float Numeric Decimal BigDecimal Boolean TrueClass
        FalseClass Hash Array Range Time Date DateTime Proc Class Module Object
        NilClass Params Param Options Option Attributes Attribute Id Ids Name
        Amount Quantity Count Total Price Rate Percentage Status State Kind Type
      ].freeze

      def refuse_unresolvable_model_param!(param)
        hint = param.type_hint.to_s
        return if hint.empty?
        return unless hint.match?(/\A[A-Z]/)
        return if NON_MODEL_HINTS.include?(hint)
        return unless param.default_source.nil?
        return if %i[rest keyrest block].include?(param.kind)

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

      def import_steps
        @imports.each do |cluster|
          add(:import_record,
              name:     cluster.name,
              model:    cluster.model,
              attrs:    cluster.attrs,
              source:   cluster.source,
              redacted: cluster.redacted,
              flags:    cluster.flags)

          @refs[cluster.table] ||= cluster.name
        end
      end

      def context_steps
        tenant_step
        auth_step
        whodunnit_step
      end

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

      def tenant_ref_for(finding)
        table = @resolver.table_for(finding.model)
        return nil if table.nil?

        tenant_tables = @resolver.required_associations(table).map(&:last)
        tenant_table  = tenant_tables.first
        return nil if tenant_table.nil?

        create_record_for(tenant_table)
      end

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

      CURRENT_USER_READS = /
        current_user | current_spree_user | spree_current_user | current_admin
        | Current\s*\. | whodunnit | PaperTrail\s*\.\s*request
      /x

      def target_may_read_current_user?
        return false unless File.file?(@target.file_path)

        Analyzer::Source.read(@target.file_path).match?(CURRENT_USER_READS)
      end

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

      def subject_step
        return unless @target.needs_subject?

        add(:construct_subject,
            class:  @target.class_name,
            kind:   @target.construction_kind,
            params: @target.initializer_params.map(&:name))
      end

      def plan
        SetupPlan.new(
          steps:            @steps,
          isolation:        @profile.isolation,
          env_fingerprint:  env_fingerprint,
          bindings:         @bindings,
          notes:            @notes,
          generation:       @generation,
          plan_id:          nil
        ).then { |draft| draft.with(plan_id: fingerprint(draft)) }
      end

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

      def add(kind, **payload)
        raise PinspecInternalError, "unknown setup step #{kind.inspect}" unless STEP_KINDS.include?(kind)

        @steps << SetupStep.new(kind: kind, payload: payload)
      end

      def next_ref(table_name)
        singular = Analyzer::Inflector.singular_candidates(table_name).first
        @counters[table_name] += 1

        "#{singular}_#{@counters[table_name]}"
      end

      def note(kind, detail)
        @notes << { kind: kind, detail: detail }
        nil
      end
    end
  end
end
