# frozen_string_literal: true

require "digest"

module Pinspec
  module Inputs
    class Hydrator
      MAX_DEPTH        = 3
      MAX_ROWS_PER_CLUSTER = 20

      VOLATILE = %w[created_at updated_at].freeze
      DB_FUNCTION_DEFAULT = /\A(?:->|gen_random_uuid|now|uuid_generate_v4|CURRENT_)/i.freeze

      def initialize(schema:, redactor:, factories:, max_depth: MAX_DEPTH,
                     max_rows: MAX_ROWS_PER_CLUSTER)
        raise ArgumentError, "factories: is required - without it an imported row " \
                            "gets a camelized table name, which is the wrong constant " \
                            "on any app whose tables sit behind an engine prefix" if factories.nil?

        @schema    = schema
        @redactor  = redactor
        @resolver  = Setup::DependencyResolver.new(schema, factories)
        @max_depth = max_depth
        @max_rows  = max_rows
      end

      def hydrate(table, rows, all_rows, target_source: "")
        @notes = []
        clusters = []
        ordinal  = 0

        @refs = {}
        @counters = Hash.new(0)
        @budget = @max_rows

        Array(rows).each do |row|
          ordinal += 1
          clusters.concat(build_cluster(table, row, all_rows, ordinal, target_source))
        end

        [clusters, @notes]
      end

      private

      def build_cluster(table, row, all_rows, ordinal, target_source)
        emitted = []

        walk = lambda do |current_table, current_row, depth|
          return nil if current_row.nil?
          return nil if depth > @max_depth
          return nil if @budget <= 0

          key = row_key(current_table, current_row)
          return @refs[key] if @refs.key?(key)

          @counters[current_table] += 1
          ref = "imported_#{singular(current_table)}_#{@counters[current_table]}"
          @refs[key] = ref
          @budget -= 1

          assoc_refs = {}

          all_parents(current_table).each do |column, parent_table|
            parent_id  = current_row[column] || current_row[column.to_sym]
            parent_row = find_row(all_rows, parent_table, parent_id)

            if parent_row.nil?
              assoc_refs[column] = handle_missing_parent(current_table, column, parent_table)
              next
            end

            parent_ref = walk.call(parent_table, parent_row, depth + 1)
            assoc_refs[column] = parent_ref.nil? ? nil : Tags.ref(parent_ref)
          end

          emitted << build_import(current_table, current_row, ref, assoc_refs, ordinal, target_source)
          ref
        end

        walk.call(table, row, 0)
        emitted
      end

      def handle_missing_parent(table, column, parent_table)
        nullable = column_of(table, column)&.nullable?

        if nullable
          note(:cross_cluster_nulled,
               "#{table}.#{column} pointed outside the sampled rows; it is nullable, " \
               "so the import leaves it null")
          return Tags.encode(nil)
        end

        note(:row_discarded,
             "#{table}.#{column} requires a #{parent_table} that was not sampled, so " \
             "that row cannot be recreated and was dropped")
        nil
      end

      def build_import(table, row, ref, assoc_refs, ordinal, target_source)
        attrs, redacted = @redactor.redact(importable_attrs(table, row), ordinal: ordinal, table: table)

        tagged = attrs.transform_values { |value| Tags.encode(value) }
        tagged.merge!(assoc_refs.compact)

        flags = []
        reads = @redactor.reads_in(target_source, redacted)
        flags << :redaction_read unless reads.empty?

        reads.each do |read|
          note(:redaction_read,
               "the target reads #{read[:attribute]} at line #{read[:line]}, and that " \
               "value was rewritten - the pin would freeze behaviour the app never has")
        end

        ImportCluster.new(
          model:    model_for(table),
          table:    table,
          name:     ref,
          attrs:    tagged,
          source:   provenance(table, row),
          redacted: redacted,
          flags:    flags
        )
      end

      def importable_attrs(table, row)
        schema_table = @schema.table(table)
        pk           = Array(schema_table&.primary_key)
        fk_columns   = all_parents(table).map(&:first)

        row.each_with_object({}) do |(column, value), out|
          name = column.to_s
          next if pk.include?(name)
          next if VOLATILE.include?(name)
          next if fk_columns.include?(name)
          next if db_function_default?(schema_table, name)

          out[name] = value
        end
      end

      def db_function_default?(schema_table, column_name)
        default = schema_table&.column(column_name)&.default
        return false if default.nil?

        default.to_s.match?(DB_FUNCTION_DEFAULT)
      end

      def provenance(table, row)
        identifier = row["id"] || row[:id] || row.values.first

        "sample:#{table}:#{Digest::SHA1.hexdigest("#{table}:#{identifier}")[0, 8]}"
      end

      def all_parents(table)
        schema_table = @schema.table(table)
        return [] if schema_table.nil?

        schema_table.columns.filter_map do |column|
          fk = @schema.fk_for(table, column.name)
          fk ? [column.name, fk.to_table] : nil
        end
      end

      def find_row(all_rows, table, id)
        return nil if id.nil?

        Array(all_rows[table] || all_rows[table.to_sym]).find do |row|
          (row["id"] || row[:id]).to_s == id.to_s
        end
      end

      def column_of(table, column_name)
        @schema.table(table)&.column(column_name)
      end

      def row_key(table, row)
        "#{table}:#{row['id'] || row[:id] || row.hash}"
      end

      def model_for(table)
        @resolver.model_for(table)
      end

      def singular(table)
        Analyzer::Inflector.singular_candidates(table).first
      end

      def note(kind, detail)
        @notes << { kind: kind, detail: detail }
        nil
      end
    end
  end
end
