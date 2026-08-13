# frozen_string_literal: true

require "digest"

module Pinspec
  module Inputs
    # Turns sampled rows into ImportClusters at *plan* time.
    #
    # This is the v0.2 -> v0.3 structural fix (spec §0, change 1). v0.1 handed the
    # probe a row id and let it fetch the row itself, so the emitted spec pointed at
    # a row that did not exist in the test database and the whole "IDs differ"
    # failure class followed. Here the row becomes an attribute hash with its
    # primary key dropped and its foreign keys rewritten to refs, and both hosts
    # recreate the same world from the same data.
    #
    # Nothing in this class opens a connection. It shapes rows that a sampler has
    # already read, which is what makes the hard part testable without a database.
    class Hydrator
      MAX_DEPTH        = 3
      MAX_ROWS_PER_CLUSTER = 20

      # Auto-volatile columns never survive into a plan: they differ every run and
      # would make a snapshot unpinnable (spec v0.3 §9).
      VOLATILE = %w[created_at updated_at].freeze
      DB_FUNCTION_DEFAULT = /\A(?:->|gen_random_uuid|now|uuid_generate_v4|CURRENT_)/i.freeze

      # rows: { "table" => [ {"id" => 1, ...}, ... ] } as read by the sampler.
      # `factories` is optional but load-bearing on any app built on an engine: the
      # model for `spree_orders` is `Spree::Order`, and no amount of camelizing a table
      # name will produce the namespace. The factory's declared `class:` is the fact
      # that does, which is why DependencyResolver#model_for already prefers it.
      # `factories` is REQUIRED, not optional. The model for `spree_orders` is
      # `Spree::Order`, and no amount of camelizing a table name produces the
      # namespace - the factory's declared `class:` is the fact that does. An optional
      # argument here meant a caller who forgot it got `SpreeOrder`, a constant that
      # does not exist, and an error inside the probe that named the app rather than
      # the omission. Now forgetting it cannot compile.
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

      # Builds one cluster per root row, including the belongs_to closure that row
      # cannot exist without. Returns [clusters, notes].
      def hydrate(table, rows, all_rows, target_source: "")
        @notes = []
        clusters = []
        ordinal  = 0

        # Shared across every root row, not per row. All of these imports land in
        # ONE plan, so a ref name has to be unique across the whole call - and two
        # sampled rows that share a parent should share one import of it rather
        # than each creating their own.
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

      # Depth-first over required parents so a parent is emitted before its child,
      # which is the order :import_record steps have to execute in.
      def build_cluster(table, row, all_rows, ordinal, target_source)
        emitted = []

        walk = lambda do |current_table, current_row, depth|
          return nil if current_row.nil?
          return nil if depth > @max_depth
          return nil if @budget <= 0

          key = row_key(current_table, current_row)
          return @refs[key] if @refs.key?(key)

          # Reserve the ref before descending, so a self-referential row cannot
          # recurse forever.
          #
          # `imported_` is a namespace, not decoration: ContextBuilder mints
          # `company_1` for records it creates, and these names are embedded in the
          # attrs below as intra-cluster refs. A collision would silently point a
          # foreign key at the wrong record.
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

      # A parent outside the sampled set. Nullable: leave it null. Required: the row
      # cannot be recreated, so it is discarded rather than imported broken.
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

      # The primary key is dropped, volatile columns are dropped, and foreign keys
      # are replaced by refs upstream. What is left is the row's own data.
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

      # Hashed by default: a spec file committed to a client's repository that maps
      # fixtures to production row ids is its own governance conversation, and the
      # audit-deliverable buyer is the one who raises it.
      def provenance(table, row)
        identifier = row["id"] || row[:id] || row.values.first

        "sample:#{table}:#{Digest::SHA1.hexdigest("#{table}:#{identifier}")[0, 8]}"
      end

      # Every foreign key, not only the required ones. A sampled row's optional
      # parent is real data worth preserving when it was sampled too, and nulling it
      # when it was not is strictly better than importing a dangling id.
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

      # Asks the resolver rather than camelizing, when it can. This was a second copy
      # of a question the resolver already answered, and the copies had drifted: on the
      # first real application it produced `SpreeOrder`, so every imported row failed
      # with `uninitialized constant SpreeOrder`. Two answers to one question is the
      # bug class pinspec's own analyzer modules were consolidated to avoid.
      # One answer, from the resolver. This was a second copy of a question the
      # resolver already answered, and the copies had drifted: on the first real
      # application it produced `SpreeOrder`, so every imported row failed with
      # `uninitialized constant SpreeOrder`. Two answers to one question is the bug
      # class the analyzer modules were consolidated to avoid.
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
