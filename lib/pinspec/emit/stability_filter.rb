# frozen_string_literal: true

require "json"

module Pinspec
  module Emit
    # M-08. Joins the two runs by case id and decides what is safe to pin.
    #
    # The declared field set is the point. v0.2 said "deep-compare", which included
    # `duration_ms` (never equal between runs) and `sql_fingerprints` (the most
    # fragile field in the record, and opt-in for pinning anyway) - so the two least
    # meaningful fields would have decided the fate of every pin.
    class StabilityFilter
      # Compared always. Everything else is either informational or opt-in.
      COMPARED = %w[status return_value error enqueued_jobs mail_deliveries db_delta].freeze

      # Compared only when SQL pins were requested.
      OPTIONAL = %w[sql_fingerprints].freeze

      NEVER_COMPARED = %w[duration_ms flags setup_error].freeze

      MAX_DIFF_LINES = 10

      Verdict = Data.define(:case_id, :stable, :cause, :diff, :observation) do
        def stable?
          stable
        end

        def to_s
          stable? ? "#{case_id} stable" : "#{case_id} unstable (#{cause})"
        end
      end

      Report = Data.define(:verdicts, :runs, :compared_fields) do
        def stable
          verdicts.select(&:stable?)
        end

        def unstable
          verdicts.reject(&:stable?)
        end

        def causes
          unstable.group_by(&:cause).transform_values(&:size)
        end

        def nothing_to_pin?
          stable.empty?
        end
      end

      def initialize(compare_sql: false)
        @compare_sql = compare_sql
      end

      def compared_fields
        @compare_sql ? COMPARED + OPTIONAL : COMPARED
      end

      # runs: [Sandbox::Result, Sandbox::Result]
      def filter(runs)
        first, *rest = Array(runs)
        raise ArgumentError, "stability needs at least one run" if first.nil?

        verdicts = first.observations.map do |observation|
          others = rest.map { |run| run.observation(observation["case_id"]) }

          verdict_for(observation, others)
        end

        Report.new(verdicts: verdicts, runs: Array(runs).size, compared_fields: compared_fields)
      end

      private

      def verdict_for(observation, others)
        case_id = observation["case_id"]

        # A case whose world could not be built is quarantined rather than pinned:
        # the plan is the problem, not the target (spec v0.3 §7 M-05.15).
        if observation["status"] == "setup_error"
          return unstable(case_id, :setup_error, setup_diff(observation), observation)
        end

        if observation["flags"].to_a.include?("escaped_transaction")
          return unstable(case_id, :escaped_transaction, "", observation)
        end

        missing = others.any?(&:nil?)
        return unstable(case_id, :missing_from_run, "", observation) if missing

        difference = others.filter_map { |other| first_difference(observation, other) }.first
        return Verdict.new(case_id: case_id, stable: true, cause: nil, diff: nil, observation: observation) if difference.nil?

        field, mine, theirs = difference
        unstable(case_id, classify(field, mine, theirs), diff_excerpt(field, mine, theirs), observation)
      end

      def unstable(case_id, cause, diff, observation)
        Verdict.new(case_id: case_id, stable: false, cause: cause, diff: diff, observation: observation)
      end

      def first_difference(mine, theirs)
        compared_fields.each do |field|
          return [field, mine[field], theirs[field]] unless mine[field] == theirs[field]
        end

        nil
      end

      # Heuristic by design, and ordered so the specific causes win. "Unstable"
      # without a cause is an accusation; with one it is a lead.
      def classify(field, mine, theirs)
        kinds = differing_tags(mine, theirs)

        return :identity_churn if kinds.any? && kinds.all? { |kind| %w[int gid seq].include?(kind) }
        return :time if kinds.any? { |kind| %w[time date].include?(kind) }
        return :float_noise if float_noise?(mine, theirs)
        return :random if kinds.include?("str")
        return :order_dependent if reordered?(mine, theirs)
        return :side_effect_churn if %w[enqueued_jobs mail_deliveries].include?(field)

        :external_io
      end

      # Which tag kinds sit at the points where the two renderings disagree. An
      # integer that changed between runs is almost always a sequence value: they
      # are not transactional, so a rolled-back case still advances them.
      def differing_tags(mine, theirs)
        left = tag_pairs(mine)
        right = tag_pairs(theirs)

        (left.keys | right.keys).filter_map do |path|
          next if left[path] == right[path]

          (left[path] || right[path])&.first
        end
      end

      # { path => [tag, value] } for every tagged node.
      def tag_pairs(value, path = "", out = {})
        case value
        when Hash
          out[path] = [value["t"], value["v"]] if value.key?("t")
          value.each { |key, inner| tag_pairs(inner, "#{path}/#{key}", out) unless key == "t" }
        when Array
          value.each_with_index { |inner, index| tag_pairs(inner, "#{path}[#{index}]", out) }
        end

        out
      end

      def float_noise?(mine, theirs)
        left = tag_pairs(mine).select { |_, (tag, _)| tag == "float" }
        right = tag_pairs(theirs)

        return false if left.empty?

        left.all? do |path, (_, value)|
          other = right[path]
          other && other[0] == "float" && (value.to_f - other[1].to_f).abs < 1e-6
        end
      end

      def reordered?(mine, theirs)
        return false unless mine.is_a?(Array) && theirs.is_a?(Array)

        mine.sort_by(&:to_s) == theirs.sort_by(&:to_s)
      end

      def setup_diff(observation)
        error = observation.dig("setup_error", "error") || {}

        "#{error['class']}: #{error['message']}"
      end

      # Capped, because a diff nobody reads is the same as no diff.
      def diff_excerpt(field, mine, theirs)
        left = render(mine).lines
        right = render(theirs).lines
        lines = ["field: #{field}"]

        [left.size, right.size].max.times do |index|
          # Two lines are added per differing row, so the check has to leave room
          # for both or the cap overshoots by one.
          break if lines.size + 2 > MAX_DIFF_LINES
          next if left[index] == right[index]

          lines << "  run1: #{left[index].to_s.chomp}"
          lines << "  run2: #{right[index].to_s.chomp}"
        end

        lines.join("\n")
      end

      def render(value)
        JSON.pretty_generate(value)
      rescue StandardError
        value.inspect
      end
    end
  end
end
