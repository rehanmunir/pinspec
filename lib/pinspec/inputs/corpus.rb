# frozen_string_literal: true

module Pinspec
  module Inputs
    class Corpus
      DEFAULT_MAX_CASES = 12

      OMIT = :__pinspec_omit__

      class << self
        def build(target:, plan:, schema: nil, max_cases: DEFAULT_MAX_CASES, imports: [])
          new(target: target, plan: plan, schema: schema, max_cases: max_cases, imports: imports).build
        end
      end

      def initialize(target:, plan:, schema: nil, max_cases: DEFAULT_MAX_CASES, imports: [])
        @target    = target
        @plan      = plan
        @schema    = schema
        @max_cases = max_cases
        @imports   = imports
      end

      def build
        cases = [base_case]
        cases.concat(boundary_cases(@max_cases - cases.size))

        InputCorpus.new(cases: dedup(cases), setup_plan: @plan)
      end

      private

      def base_case
        build_case("c001", :defaults) { |param| base_value_for(param) }
      end

      def boundary_cases(budget)
        return [] if budget <= 0

        variations = round_robin(ctor_variations, method_variations).first(budget)

        variations.each_with_index.map do |(param, value), index|
          build_case(format("c%03d", index + 2), :boundary) do |candidate|
            candidate.equal?(param) ? value : base_value_for(candidate)
          end
        end
      end

      def round_robin(first, second)
        interleaved = []
        [first.size, second.size].max.times do |index|
          interleaved << first[index] if first[index]
          interleaved << second[index] if second[index]
        end

        interleaved
      end

      def ctor_variations
        variations_for(@target.initializer_params)
      end

      def method_variations
        variations_for(@target.params)
      end

      def variations_for(params)
        params.flat_map do |param|
          next [] if bound?(param)
          next [] if %i[rest keyrest].include?(param.kind)

          base = base_value_for(param)
          values = Boundary.values_for(param, column: column_for(param))
                           .reject { |value| value == base }

          values += [OMIT] if Boundary.omittable?(param)

          values.map { |value| [param, value] }
        end
      end

      def build_case(id, origin)
        ctor_args, ctor_kwargs = split_params(@target.initializer_params) { |param| yield(param) }
        args, kwargs           = split_params(@target.params) { |param| yield(param) }

        InputCase.new(
          id:          id,
          ctor_args:   ctor_args,
          ctor_kwargs: ctor_kwargs,
          args:        args,
          kwargs:      kwargs,
          origin:      origin
        )
      end

      def split_params(params)
        positional = []
        keyword    = {}

        params.each do |param|
          value = yield(param)
          next if value == OMIT

          if %i[keyreq key].include?(param.kind)
            keyword[param.name.to_s] = value
          elsif %i[req opt].include?(param.kind)
            positional << value
          end
        end

        [positional, keyword]
      end

      def base_value_for(param)
        ref = @plan.binding_for(param.name)
        return Tags.ref(ref) if ref

        Boundary.base_value(param, column: column_for(param))
      end

      def column_for(param)
        return nil if @schema.nil?

        matches = @schema.tables.filter_map { |table| table.column(param.name) }
        return nil if matches.empty?

        types = matches.map(&:type).uniq
        types.size == 1 ? matches.first : nil
      end

      def bound?(param)
        !@plan.binding_for(param.name).nil?
      end

      def dedup(cases)
        seen = {}

        cases.each_with_object([]) do |input_case, kept|
          signature = input_case.signature
          next if seen[signature]

          seen[signature] = true
          kept << input_case
        end
      end
    end
  end
end
