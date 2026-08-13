# frozen_string_literal: true

module Pinspec
  module Setup
    class DependencyResolver
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

      TEMPORAL_TYPES = %i[datetime timestamp timestamptz date time].freeze

      def initialize(schema, factories)
        @schema    = schema
        @factories = factories
      end

      def table_for(model_name)
        return nil if model_name.nil?

        table_candidates_for(model_name).each do |candidate|
          table = @schema.table(candidate)
          return table if table
        end

        nil
      end

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

      def model_for(table_name)
        declared = @factories.factories.find { |f| table_for(f.model)&.name == table_name.to_s }
        return declared.model if declared

        camelize(Analyzer::Inflector.singular_candidates(table_name).first)
      end

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

      def required_associations(table)
        return [] if table.nil?

        table.required_columns.filter_map do |column|
          fk = @schema.fk_for(table.name, column.name)
          next unless fk

          [column.name, fk.to_table]
        end
      end

      def required_scalars(table)
        return [] if table.nil?

        association_columns = required_associations(table).map(&:first)
        table.required_columns.reject { |column| association_columns.include?(column.name) }
      end

      def creation_order(root_tables, prune: ->(_table) { false })
        ordered = []
        state   = {}

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
              next if parent == table_name

              walk.call(parent, path + [table_name])
            end
          end

          state[table_name] = :done
          ordered << table_name
        end

        Array(root_tables).compact.uniq.each { |name| walk.call(name, []) }
        ordered
      end

      def self_referential_required?(table)
        required_associations(table).any? { |_column, parent| parent == table&.name }
      end

      def placeholder_for(column, frozen_time:, uniquifier: nil)
        return frozen_value(column, frozen_time) if TEMPORAL_TYPES.include?(column.type)

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
