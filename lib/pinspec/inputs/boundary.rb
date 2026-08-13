# frozen_string_literal: true

module Pinspec
  module Inputs
    # Boundary values for scalar parameters, chosen from the parameter's type hint
    # and its default's source text.
    #
    # Deliberately small. pinspec does not search for inputs that reach new
    # branches - that is Diffblue's decade-deep moat and an explicit non-goal
    # (spec v0.3 §3). What it does is try the obvious edges and be honest that
    # branch coverage of the resulting pins is partial.
    module Boundary
      # Ordered by how likely each is to be the interesting one, because the
      # --cases budget cuts from the end.
      BY_TYPE = {
        "Integer" => [0, 1, -1],
        "Float"   => [0.0, 1.0, -1.0],
        "Boolean" => [true, false],
        "String"  => ["", "pinspec"],
        "Symbol"  => nil, # only the declared default is meaningful
        "Array"   => [[]],
        "Hash"    => [{}],
        "Proc"    => nil, # cannot cross the JSON boundary
        "Date"    => [PINSPEC_EPOCH[0, 10]],
        "Time"    => [PINSPEC_EPOCH]
      }.freeze

      # A decimal is a string on the wire; a Float here would silently change a
      # pinned total.
      DECIMAL_HINTS = %w[BigDecimal Decimal].freeze

      class << self
        # Every value pinspec will try for one parameter, tagged, best first.
        # A model-typed parameter is not here: it is always the plan's ref.
        def values_for(param, column: nil, default_first: true)
          declared = default_value(param)
          edges    = edges_for(param, column)

          ordered = default_first ? [declared, *edges] : [*edges, declared]

          # :__none__ marks absence; nil is a legitimate boundary value, so
          # Array#compact would throw away the wrong thing.
          present(ordered).map { |value| encode(value, param) }.uniq
        end

        # The value a parameter takes when pinspec is not varying it: its declared
        # default, or the first boundary value when it is required.
        def base_value(param, column: nil)
          declared = default_value(param)
          return Tags.encode(declared) unless declared == :__none__

          encode(Array(edges_for(param, column)).first, param)
        end

        # An optional parameter can also simply be omitted, which exercises the
        # default expression itself - and a default expression can read the clock
        # or a feature flag, which M-01 already detects.
        def omittable?(param)
          param.optional?
        end

        private

        # A decimal is a string on the wire under its own tag: a "str" tag would let
        # the probe hand a String to code expecting a BigDecimal, and a "float" tag
        # would let a pinned total drift.
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

        # :__none__ rather than nil, because nil is a real default.
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
          else :__none__ # a computed default; pinspec omits the argument instead
          end
        end

        # Precedence: the parameter's own default literal (already handled by the
        # caller), then a schema column of the same name, then the name-derived
        # hint. The column is a fact; the hint is a guess from a word.
        def edges_for(param, column = nil)
          hint = param.type_hint

          return decimal_edges if DECIMAL_HINTS.include?(hint)
          return BY_TYPE.fetch(hint) if BY_TYPE.key?(hint)

          from_column = column && edges_for_column_type(column.type)
          return from_column if from_column

          # Nothing known. Passing nil at least exercises the nil branch, which is
          # the most common source of a legacy NoMethodError.
          [nil]
        end

        # A schema column type maps onto the same edge sets.
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
