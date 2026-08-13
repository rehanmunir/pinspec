# frozen_string_literal: true

module Pinspec
  module Inputs
    # M-06. Builds the InputCorpus: which arguments pinspec will actually invoke the
    # target with.
    #
    # The allocation is the part worth reading. A `#call` target keeps its
    # dependencies in the constructor, so constructor parameters usually outnumber
    # method parameters - and spending a 12-case budget entirely on the constructor
    # would leave the method's own arguments untested. So: one all-defaults case
    # first, then one variation per parameter round-robin across the constructor and
    # the method, until the budget runs out (spec v0.3 §7 M-06).
    class Corpus
      DEFAULT_MAX_CASES = 12

      # Marks an argument pinspec leaves out entirely, so the method's own default
      # expression runs. That matters: a default can read the clock or a feature
      # flag, which is exactly what M-01's clock-site detection scans for.
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

        # The cap is already enforced by the budget passed to boundary_cases; dedup
        # only ever removes.
        InputCorpus.new(cases: dedup(cases), setup_plan: @plan)
      end

      private

      # Case one: every parameter at its declared default, every model-typed
      # parameter at the ref the plan built for it. If a target works at all, it
      # works here - so a failure in case one is a setup problem, not an edge case.
      def base_case
        build_case("c001", :defaults) { |param| base_value_for(param) }
      end

      # One factor at a time: vary a single parameter, hold everything else at its
      # base value. Anything that changes is attributable to that parameter.
      def boundary_cases(budget)
        return [] if budget <= 0

        variations = round_robin(ctor_variations, method_variations).first(budget)

        variations.each_with_index.map do |(param, value), index|
          build_case(format("c%03d", index + 2), :boundary) do |candidate|
            candidate.equal?(param) ? value : base_value_for(candidate)
          end
        end
      end

      # Interleaved rather than concatenated, so the budget reaches both lists.
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

      # Model-typed parameters are excluded: their value is the plan's ref, and
      # varying a ref would mean varying the world rather than the input.
      def variations_for(params)
        params.flat_map do |param|
          next [] if bound?(param)
          next [] if %i[rest keyrest].include?(param.kind)

          base = base_value_for(param)
          values = Boundary.values_for(param, column: column_for(param))
                           .reject { |value| value == base }

          # Leaving an optional argument out is its own boundary: it runs the
          # default expression rather than a value pinspec chose.
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

      # Positional and keyword arguments are separated here rather than at the call
      # site, because the probe forwards them through one version-guarded shim and
      # cannot re-derive which was which (spec v0.3 §6).
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

      # A model-typed parameter is always the record the plan built for it.
      def base_value_for(param)
        ref = @plan.binding_for(param.name)
        return Tags.ref(ref) if ref

        Boundary.base_value(param, column: column_for(param))
      end

      # A parameter named `region` when the schema has a `region` column is almost
      # certainly that column. Only an unambiguous type counts: if two tables
      # disagree about what `status` is, the schema is not telling us anything.
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

      # Boundary cases cannot currently collide - each varies a different parameter,
      # and per-parameter values are already uniq'd against the base. This becomes
      # load-bearing when sampled cases land, since a real row can reproduce a
      # boundary value exactly.
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
