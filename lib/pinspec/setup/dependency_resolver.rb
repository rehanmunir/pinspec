# frozen_string_literal: true

module Pinspec
  module Setup
    # M-05's half that answers structural questions about the schema: which table
    # a model name means, which associations a row cannot exist without, and in
    # what order rows have to be created.
    #
    # Kept separate from ContextBuilder because these answers are pure functions of
    # the SchemaGraph, and because "what does Invoice mean" is the question most
    # likely to be wrong on a real app - it deserves its own tests.
    class DependencyResolver
      # Placeholder values by column type. Deterministic by construction: the same
      # plan must produce the same world on every run and in both hosts, so nothing
      # here is random and nothing reads a clock.
      PLACEHOLDERS = {
        string:      "pinspec",
        text:        "pinspec",
        citext:      "pinspec",
        integer:     1,
        bigint:      1,
        smallint:    1,
        tinyint:     1,
        float:       1.0,
        decimal:     "1.0",
        numeric:     "1.0",
        money:       "1.0",
        boolean:     false,
        json:        {},
        jsonb:       {},
        hstore:      {},
        xml:         "<pinspec/>",
        uuid:        "00000000-0000-4000-8000-000000000001",
        inet:        "127.0.0.1",
        cidr:        "127.0.0.0/8",
        macaddr:     "00:00:00:00:00:01",
        binary:      "pinspec",
        blob:        "pinspec",
        interval:    "P1D",
        ltree:       "pinspec",
        oid:         1,
        bit:         "0",
        bit_varying: "0"
      }.freeze

      # Filled from the plan's frozen clock rather than from Time.now.
      TEMPORAL_TYPES = %i[datetime timestamp timestamptz date time].freeze

      def initialize(schema, factories)
        @schema    = schema
        @factories = factories
      end

      # "Invoice" or "Billing::Customer" => the Table it lives in, or nil.
      #
      # Candidate-and-verify, the same discipline M-02 uses: generate every table
      # name the model could mean and keep the one that exists. Rails drops the
      # namespace unless a table_name_prefix is configured, so both forms are
      # candidates and the schema settles it.
      def table_for(model_name)
        return nil if model_name.nil?

        table_candidates_for(model_name).each do |candidate|
          table = @schema.table(candidate)
          return table if table
        end

        nil
      end

      # A parameter's type hint is a guess made from its *name*, and real names
      # carry qualifiers: source_company, new_invoice, parent_account,
      # original_line_item. So try the whole hint first - a real SourceCompany
      # model must win - then progressively drop leading words.
      def table_for_type_hint(hint)
        return nil if hint.nil?

        words = hint.to_s.scan(/[A-Z][a-z0-9]*/)

        if words.size < 2
          direct = table_for(hint)
          return direct if direct
        else
          words.each_index do |index|
            table = table_for(words[index..].join)
            return table if table
          end
        end

        table_from_factory_class(hint) || table_from_unique_prefix(hint)
      end

      # A Rails ENGINE puts its tables behind a prefix: Spree::Order lives in
      # `spree_orders`, and a parameter named `order` therefore names a model whose
      # table its own name cannot reach. That is not an edge case - it is most of the
      # commerce codebases pinspec exists for (Spree, Solidus, and anything built on
      # an engine), and on the first real application it was the difference between a
      # plan that builds an order and a plan that passes nil.
      #
      # The app states the mapping itself: `factory :order, class: Spree::Order`. A
      # declared class is a fact rather than a convention, which is the same reason
      # `model_for` already prefers it, so it is consulted before any guessing.
      def table_from_factory_class(hint)
        wanted = underscore(hint.to_s.split("::").last)

        @factories.factories.each do |factory|
          next unless factory.name.to_s == wanted
          next if factory.model.nil?

          table = table_for(factory.model)
          return table if table
        end

        nil
      end

      # Last resort, for an app with no factory to ask, and only when the schema
      # gives one answer. OFN has BOTH `spree_orders` and `proxy_orders`, so `order`
      # is genuinely ambiguous there and this declines rather than picking - the
      # factory above is what resolves it. Guessing here would bind a target to the
      # wrong table and pin behaviour that belongs to a different model.
      def table_from_unique_prefix(hint)
        candidates = Analyzer::Inflector.table_candidates(underscore(hint.to_s.split("::").last))
        matches = @schema.tables.select do |table|
          candidates.any? { |candidate| table.name.end_with?("_#{candidate}") }
        end

        matches.size == 1 ? matches.first : nil
      end

      def table_candidates_for(model_name)
        parts       = model_name.to_s.split("::")
        demodulized = underscore(parts.last)
        namespaced  = parts.map { |part| underscore(part) }.join("_")

        (Analyzer::Inflector.table_candidates(demodulized) +
          Analyzer::Inflector.table_candidates(namespaced)).uniq
      end

      # The model constant a schema-driven create! has to name. A factory's own
      # declared class wins, because it is a fact rather than a convention.
      def model_for(table_name)
        declared = @factories.factories.find { |f| table_for(f.model)&.name == table_name.to_s }
        return declared.model if declared

        camelize(Analyzer::Inflector.singular_candidates(table_name).first)
      end

      # The factory pinspec would use for a table, or nil. A factory that never
      # persists cannot found a world, so it is declined here rather than failing
      # confusingly inside the probe.
      def factory_for(table_name)
        candidates = @factories.factories.select { |f| table_for(f.model)&.name == table_name.to_s }

        candidates.find(&:persists?)
      end

      def declined_factory_for(table_name)
        @factories.factories
                  .select { |f| table_for(f.model)&.name == table_name.to_s }
                  .reject(&:persists?)
                  .first
      end

      # Foreign keys a row cannot exist without: NOT NULL, no default, and not the
      # primary key. A nullable belongs_to is left null on purpose - the smallest
      # world that can exist is the one least likely to surprise a reader.
      def required_associations(table)
        return [] if table.nil?

        table.required_columns.filter_map do |column|
          fk = @schema.fk_for(table.name, column.name)
          next unless fk

          [column.name, fk.to_table]
        end
      end

      # Columns a schema-driven create! must supply a value for, excluding those
      # satisfied by an association.
      def required_scalars(table)
        return [] if table.nil?

        association_columns = required_associations(table).map(&:first)
        table.required_columns.reject { |column| association_columns.include?(column.name) }
      end

      # Depth-first postorder over required associations, so a parent is always
      # created before the row that needs it.
      #
      # `prune` marks tables whose parents someone else builds - a factory creates
      # its own associations, so descending past one would create a second, unused
      # parent that is not even the one the factory used.
      #
      # A cycle here is genuinely unresolvable rather than merely awkward: two
      # tables whose foreign keys to each other are both NOT NULL cannot have a
      # first row. Nullable links never enter this graph, which is exactly why
      # `optional: true` breaks a cycle in practice.
      def creation_order(root_tables, prune: ->(_table) { false })
        ordered = []
        state   = {} # table name => :visiting | :done

        walk = lambda do |table_name, path|
          case state[table_name]
          when :done then return
          when :visiting
            raise UnresolvableSetup.new(
              :association_cycle,
              "#{path.join(' -> ')} -> #{table_name}: these tables require each " \
              "other through NOT NULL foreign keys, so no row can be created " \
              "first. Making one side optional would break the cycle."
            )
          end

          state[table_name] = :visiting

          unless prune.call(table_name)
            table = @schema.table(table_name)
            required_associations(table).each do |_column, parent|
              next if parent == table_name # self-reference through a NOT NULL column

              walk.call(parent, path + [table_name])
            end
          end

          state[table_name] = :done
          ordered << table_name
        end

        Array(root_tables).compact.uniq.each { |name| walk.call(name, []) }
        ordered
      end

      # A self-referential NOT NULL foreign key cannot be satisfied either: the row
      # would have to exist before it is created.
      def self_referential_required?(table)
        required_associations(table).any? { |_column, parent| parent == table&.name }
      end

      def placeholder_for(column, frozen_time:, uniquifier: nil)
        return frozen_value(column, frozen_time) if TEMPORAL_TYPES.include?(column.type)

        # An unmodelled type has no placeholder, and both helpers below pass nil
        # through, so the caller sees nil and decides whether to refuse.
        base = PLACEHOLDERS[column.type]
        base = apply_uniquifier(base, column, uniquifier) if uniquifier
        clamp_to_limit(base, column)
      end

      def unique_columns(table)
        return [] if table.nil?

        table.unique_indexes.flat_map(&:columns).uniq
      end

      private

      def frozen_value(column, frozen_time)
        case column.type
        when :date then frozen_time[0, 10]
        when :time then frozen_time[11, 8]
        else frozen_time
        end
      end

      # Only strings can carry a suffix; a unique integer column gets a distinct
      # number instead.
      def apply_uniquifier(base, column, uniquifier)
        case base
        when String  then "#{base}-#{uniquifier}"
        when Integer then base + uniquifier_ordinal(uniquifier)
        else base
        end
      end

      def uniquifier_ordinal(uniquifier)
        uniquifier.to_s.scan(/\d+/).map(&:to_i).sum
      end

      def clamp_to_limit(value, column)
        return value unless value.is_a?(String)
        return value if column.limit.nil? || !column.limit.is_a?(Integer)

        value[0, column.limit]
      end

      def underscore(str)
        str.to_s
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end

      def camelize(str)
        str.to_s.split("_").map { |part| part.sub(/\A[a-z]/, &:upcase) }.join
      end
    end
  end
end
