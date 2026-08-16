# frozen_string_literal: true

module Pinspec
  module Inputs
    module Boundary
      BY_TYPE = {
        "Integer" => [0, 1, -1],
        "Float"   => [0.0, 1.0, -1.0],
        "Boolean" => [true, false],
        "String"  => ["", "pinspec"],
        "Symbol"  => nil,
        "Array"   => [[]],
        "Hash"    => [{}],
        "Proc"    => nil,
        "Date"    => [PINSPEC_EPOCH[0, 10]],
        "Time"    => [PINSPEC_EPOCH]
      }.freeze

      DECIMAL_HINTS = %w[BigDecimal Decimal].freeze

      class << self
        def values_for(param, column: nil)
          declared = default_value(param)
          edges    = edges_for(param, column)
          ordered = [declared, *edges]

          present(ordered).map { |value| encode(value, param) }.uniq
        end

        def base_value(param, column: nil)
          declared = default_value(param)
          return Tags.encode(declared) unless declared == :__none__

          encode(Array(edges_for(param, column)).first, param)
        end

        def omittable?(param)
          param.optional?
        end

        private

        def encode(value, param)
          return Tags.decimal(value) if decimal?(param) && !value.nil?

          Tags.encode(value)
        end

        def decimal?(param)
          DECIMAL_HINTS.include?(param.type_hint)
        end

        def present(values)
          values.reject { |value| value == :__none__ }
        end

        def default_value(param)
          return :__none__ if param.default_source.nil?

          literal_from_source(param.default_source)
        end

        def literal_from_source(source)
          text = source.to_s.strip

          case text
          when "nil"                then nil
          when "true"               then true
          when "false"              then false
          when /\A:([A-Za-z_]\w*)\z/ then Regexp.last_match(1).to_sym
          when /\A-?\d+\z/          then text.to_i
          when /\A-?\d+\.\d+\z/     then text.to_f
          when /\A"([^"]*)"\z/, /\A'([^']*)'\z/ then Regexp.last_match(1)
          when "[]"                 then []
          when "{}"                 then {}
          else :__none__
          end
        end

        def edges_for(param, column = nil)
          hint = param.type_hint

          return decimal_edges if DECIMAL_HINTS.include?(hint)
          return BY_TYPE.fetch(hint) if BY_TYPE.key?(hint)

          from_column = column && edges_for_column_type(column.type)
          return from_column if from_column

          [nil]
        end

        def edges_for_column_type(type)
          case type
          when :string, :text, :citext             then BY_TYPE.fetch("String")
          when :integer, :bigint, :smallint        then BY_TYPE.fetch("Integer")
          when :float                              then BY_TYPE.fetch("Float")
          when :decimal, :numeric, :money          then decimal_edges
          when :boolean                            then BY_TYPE.fetch("Boolean")
          when :date                               then BY_TYPE.fetch("Date")
          when :datetime, :timestamp, :timestamptz then BY_TYPE.fetch("Time")
          when :json, :jsonb, :hstore              then BY_TYPE.fetch("Hash")
          end
        end

        def decimal_edges
          %w[0.0 1.0 -1.0]
        end
      end
    end
  end
end
