# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    class SchemaReader
      include Source

      KNOWN_TYPES = %i[
        string text citext
        integer bigint smallint tinyint float decimal numeric money
        datetime timestamp timestamptz time date
        binary blob boolean
        json jsonb hstore xml
        uuid inet cidr macaddr
        daterange numrange tsrange tstzrange int4range int8range
        interval bit bit_varying oid ltree
        primary_key serial bigserial virtual enum
      ].freeze

      HANDLED_STATEMENTS = %i[create_table add_index add_foreign_key enable_extension].freeze

      NON_COLUMN_CALLS = %i[index check_constraint exclusion_constraint unique_constraint].freeze

      DEFAULT_ID_TYPE = :bigint

      class << self
        def read(app_root = ".")
          schema = File.join(app_root, "db", "schema.rb")
          return parse(schema) if File.file?(schema)

          structure = File.join(app_root, "db", "structure.sql")
          if File.file?(structure)
            raise SchemaFormatUnsupported, structure_sql_message(structure)
          end

          raise TargetNotFound,
                "no db/schema.rb under #{app_root} (and no db/structure.sql either); " \
                "is this a Rails application root?"
        end

        def parse(path)
          new(path).parse
        end

        def structure_sql_message(path)
          "#{path} is a SQL-format schema; pinspec reads the Ruby schema DSL. " \
            "Generate one with `bin/rails db:schema:dump` after setting " \
            "`config.active_record.schema_format = :ruby`, or keep both formats " \
            "while pinspec runs. SQL-format support is spec open question 2."
        end
      end

      def initialize(path)
        @path = path
      end

      def parse
        raise SchemaFormatUnsupported, self.class.structure_sql_message(@path) if @path.end_with?(".sql")

        read_source
        collect_statements

        tables       = @raw_tables.map { |raw| build_table(raw) }
        foreign_keys = resolve_foreign_keys(tables)

        SchemaGraph.new(
          tables:             tables,
          fk_map:             foreign_keys.to_h { |fk| [fk.key, fk.to_table] },
          foreign_keys:       foreign_keys,
          skipped_statements: build_skipped(tables.map(&:name))
        )
      end

      private

      def read_source
        raise TargetNotFound, "no such file: #{@path}" unless File.file?(@path)

        result = Prism.parse(Source.read(@path))

        unless result.success?
          first = result.errors.first
          raise UnparsableSource,
                "#{@path} is not valid Ruby: #{first.message} (line #{first.location.start_line})"
        end

        @program = result.value
      end

      def collect_statements
        @raw_tables  = []
        @raw_indexes = []
        @raw_fks     = []
        @assoc_refs  = []
        @skipped     = []

        Array(define_block_body).each { |statement| visit_top_level(statement) }
      end

      def define_block_body
        found = nil

        each_node(@program) do |node|
          next if found
          next unless node.is_a?(Prism::CallNode) && node.name == :define
          next unless node.receiver&.slice.to_s.start_with?("ActiveRecord::Schema")

          found = node.block
        end

        unless found
          raise UnparsableSource,
                "#{@path} has no ActiveRecord::Schema.define block; " \
                "pinspec expected a Rails schema dump."
        end

        found.body&.body
      end

      def visit_top_level(node)
        return unless node.is_a?(Prism::CallNode)

        unless HANDLED_STATEMENTS.include?(node.name)
          return skip(
            node.name,
            table: first_string_argument(node),
            line:  node.location.start_line,
            sql:   keyword_options(Array(node.arguments&.arguments))[:sql_definition]
          )
        end

        case node.name
        when :create_table      then collect_table(node)
        when :add_index         then collect_add_index(node)
        when :add_foreign_key   then collect_add_foreign_key(node)
        when :enable_extension  then nil
        end
      end

      def collect_table(node)
        args    = Array(node.arguments&.arguments)
        name    = decode(args.first).to_s
        options = keyword_options(args)

        raw = {
          name:    name,
          options: options,
          line:    node.location.start_line,
          columns: [],
          indexes: []
        }

        Array(node.block&.body&.body).each { |statement| visit_column(statement, raw) }

        @raw_tables << raw
      end

      def visit_column(node, raw)
        return unless node.is_a?(Prism::CallNode)
        return unless node.receiver.is_a?(Prism::LocalVariableReadNode)

        args    = Array(node.arguments&.arguments)
        options = keyword_options(args)
        line    = node.location.start_line

        case node.name
        when :index
          raw[:indexes] << build_index(args, options)
        when :references, :belongs_to
          collect_reference(args, options, raw, line)
        when :timestamps
          %w[created_at updated_at].each do |timestamp|
            raw[:columns] << column(timestamp, :datetime, options.merge(null: false), line: line)
          end
        when :column
          raw[:columns] << typed_column(decode(args[0]).to_s, decode(args[1]), options, line: line)
        when *NON_COLUMN_CALLS
          nil
        else
          raw[:columns] << typed_column(decode(args.first).to_s, node.name, options, line: line)
        end
      end

      def collect_reference(args, options, raw, line)
        stem = decode(args.first).to_s
        type = options.fetch(:type, DEFAULT_ID_TYPE)
        type = type.to_sym if type.respond_to?(:to_sym)

        raw[:columns] << column("#{stem}_id", type, options, line: line)

        if options[:polymorphic] == true
          raw[:columns] << column("#{stem}_type", :string, options, line: line)

          return
        end

        @assoc_refs << {
          from_table: raw[:name],
          column:     "#{stem}_id",
          stem:       stem,
          line:       line
        }
      end

      def collect_add_index(node)
        args    = Array(node.arguments&.arguments)
        options = keyword_options(args)

        @raw_indexes << {
          table: decode(args.first).to_s,
          index: build_index(args.drop(1), options)
        }
      end

      def collect_add_foreign_key(node)
        args     = Array(node.arguments&.arguments)
        options  = keyword_options(args)
        from, to = decode(args[0]).to_s, decode(args[1]).to_s

        @raw_fks << {
          from_table:  from,
          to_table:    to,
          column:      options[:column]&.to_s,
          primary_key: options[:primary_key]&.to_s,
          on_delete:   options[:on_delete]
        }
      end

      def build_table(raw)
        options = raw[:options]

        columns = raw[:columns]
        if implicit_id?(options)
          id_column = column("id", id_type(options) || DEFAULT_ID_TYPE, { null: false }, line: raw[:line])
          columns = [id_column] + columns
        end

        columns.each do |col|
          next unless col.unknown_type?

          skip(:unknown_column_type, table: raw[:name], column: col.name, line: col.line)
        end

        Table.new(
          name:        raw[:name],
          primary_key: primary_key(options),
          id_type:     id_type(options),
          columns:     columns,
          indexes:     raw[:indexes] + indexes_for(raw[:name])
        )
      end

      def implicit_id?(options)
        return false if options[:id] == false
        return false if options.key?(:primary_key) && options[:id] == false

        true
      end

      def primary_key(options)
        return options[:primary_key].then { |pk| pk.is_a?(Array) ? pk.map(&:to_s) : pk.to_s } if options[:primary_key]
        return nil if options[:id] == false

        "id"
      end

      def id_type(options)
        declared = options[:id]
        return nil if declared == false
        return DEFAULT_ID_TYPE if declared.nil? || declared == true

        declared.to_sym
      end

      def indexes_for(table_name)
        @raw_indexes.select { |entry| entry[:table] == table_name }.map { |entry| entry[:index] }
      end

      def resolve_foreign_keys(tables)
        table_names = tables.map(&:name)
        out = {}

        @raw_fks.each do |fk|
          column = fk[:column] || implicit_fk_column(fk[:from_table], fk[:to_table], tables)

          unless column
            skip(:unattachable_foreign_key, table: fk[:from_table], line: 0)
            next
          end

          out["#{fk[:from_table]}.#{column}"] = ForeignKey.new(
            from_table:  fk[:from_table],
            column:      column,
            to_table:    fk[:to_table],
            primary_key: fk[:primary_key] || "id",
            on_delete:   fk[:on_delete],
            source:      :foreign_key
          )
        end

        @assoc_refs.each do |ref|
          key = "#{ref[:from_table]}.#{ref[:column]}"
          next if out.key?(key)

          target = match_table(ref[:stem], table_names)
          next unless target

          out[key] = ForeignKey.new(
            from_table:  ref[:from_table],
            column:      ref[:column],
            to_table:    target,
            primary_key: "id",
            on_delete:   nil,
            source:      :references
          )
        end

        heuristic_foreign_keys(table_names).each do |fk|
          out[fk.key] = fk unless out.key?(fk.key)
        end

        out.values.sort_by(&:key)
      end

      def heuristic_foreign_keys(table_names)
        @raw_tables.flat_map do |raw|
          column_names = raw[:columns].map(&:name)

          raw[:columns].filter_map do |col|
            next unless col.name.end_with?("_id")
            next unless integerish?(col.type)

            stem = col.name.delete_suffix("_id")

            next if column_names.include?("#{stem}_type")

            target = match_table(stem, table_names)
            next unless target

            ForeignKey.new(
              from_table:  raw[:name],
              column:      col.name,
              to_table:    target,
              primary_key: "id",
              on_delete:   nil,
              source:      :heuristic
            )
          end
        end
      end

      def integerish?(type)
        %i[integer bigint smallint uuid].include?(type)
      end

      def match_table(stem, table_names)
        Inflector.table_candidates(stem).find { |candidate| table_names.include?(candidate) }
      end

      def implicit_fk_column(from_table, to_table, tables)
        existing = tables.find { |t| t.name == from_table }&.columns&.map(&:name) || []

        Inflector.singular_candidates(to_table)
                 .map { |singular| "#{singular}_id" }
                 .find { |candidate| existing.include?(candidate) }
      end

      def build_index(args, options)
        columns = decode(args.first)
        columns = [columns].compact unless columns.is_a?(Array)

        Index.new(
          columns: columns.map(&:to_s),
          name:    options[:name]&.to_s,
          unique:  options[:unique] == true,
          where:   options[:where]
        )
      end

      def typed_column(name, type, options, line: 0)
        normalized = normalize_type(type)

        column(name, normalized || type, options, unknown: normalized.nil?, line: line)
      end

      def normalize_type(type)
        text = type.to_s.strip.downcase
        return nil if text.empty?

        candidate = text.split(/[\s(]/).first.to_sym
        KNOWN_TYPES.include?(candidate) ? candidate : nil
      end

      def column(name, type, options, unknown: false, line: 0)
        Column.new(
          name:         name,
          type:         type.to_s.to_sym,
          null:         options[:null],
          default:      options[:default],
          limit:        options[:limit],
          precision:    options[:precision],
          scale:        options[:scale],
          array:        options[:array] == true,
          unknown_type: unknown,
          line:         line
        )
      end

      def first_string_argument(node)
        Array(node.arguments&.arguments).grep(Prism::StringNode).first&.unescaped
      end

      def skip(kind, table: nil, column: nil, line: 0, sql: nil)
        @skipped << { kind: kind.to_sym, table: table, column: column, line: line, sql: sql }
      end

      def build_skipped(table_names)
        @skipped
          .map do |raw|
            SkippedStatement.new(
              kind:       raw[:kind],
              table:      raw[:table],
              column:     raw[:column],
              references: referenced_tables(raw[:sql], table_names) - [raw[:table]],
              file:       @path,
              line:       raw[:line],
              relevant:   nil
            )
          end
          .sort_by { |statement| [statement.line, statement.kind.to_s, statement.column.to_s] }
      end

      def referenced_tables(sql, table_names)
        return [] if sql.nil?

        text = sql.to_s.downcase
        table_names.select { |name| text.match?(/\b#{Regexp.escape(name.downcase)}\b/) }
      end

    end
  end
end
