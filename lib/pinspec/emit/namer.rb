# frozen_string_literal: true

require "json"

module Pinspec
  module Emit
    class Namer
      MAX_DESCRIPTION = 120

      Facts = Data.define(:case_id, :origin, :outcome, :method_name, :class_name, :parameters)

      def initialize(target:, enabled: false, client: nil)
        @target = target
        @enabled = enabled
        @client = client
      end

      def enabled?
        @enabled && !@client.nil?
      end

      def describe(cases)
        facts = cases.map { |input_case, observation| facts_for(input_case, observation) }
        fallback = facts.to_h { |fact| [fact.case_id, deterministic(fact)] }

        return fallback unless enabled?

        improved = request(facts)
        fallback.merge(sanitize(improved, fallback))
      rescue StandardError
        fallback
      end

      def payload(facts)
        {
          "task" => "Describe each characterization test case in one short phrase.",
          "constraints" => [
            "Describe only the INPUTS and the kind of outcome.",
            "Never invent or state a concrete expected value.",
            "One phrase per case, at most #{MAX_DESCRIPTION} characters."
          ],
          "cases" => facts.map do |fact|
            {
              "id" => fact.case_id,
              "origin" => fact.origin.to_s,
              "outcome_kind" => fact.outcome.to_s,
              "method" => fact.method_name.to_s,
              "class" => fact.class_name.to_s,
              "parameter_names" => fact.parameters.map(&:to_s)
            }
          end
        }
      end

      private

      def facts_for(input_case, observation)
        Facts.new(
          case_id: input_case.id,
          origin: input_case.origin,
          outcome: observation["status"] == "raised" ? :raises : :returns,
          method_name: @target.method_name,
          class_name: @target.class_name,
          parameters: @target.input_params.map(&:name)
        )
      end

      def deterministic(fact)
        verb = fact.outcome == :raises ? "raises" : "returns the pinned value"

        "#{fact.method_name} #{verb} (#{fact.case_id}, #{fact.origin})"
      end

      def request(facts)
        response = @client.call(payload(facts))

        parsed = response.is_a?(String) ? JSON.parse(response) : response
        Array(parsed["cases"]).to_h { |entry| [entry["id"], entry["description"]] }
      end

      def sanitize(improved, fallback)
        improved.each_with_object({}) do |(case_id, description), out|
          next unless fallback.key?(case_id)
          next unless description.is_a?(String)

          text = description.strip
          next if text.empty? || text.length > MAX_DESCRIPTION
          next if suspicious?(text)

          out[case_id] = "#{text} (#{case_id})"
        end
      end

      def suspicious?(text)
        return true if text.match?(/=>|\{"t"|\bexpect\b|\beq\(/)
        return true if text.match?(/\d{3,}/)
        return true if text.count('"') > 2

        false
      end
    end
  end
end
