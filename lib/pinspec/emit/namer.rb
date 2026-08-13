# frozen_string_literal: true

require "json"

module Pinspec
  module Emit
    # M-10. The only place an LLM touches pinspec, and it can only touch names.
    #
    # Value-blindness is STRUCTURAL, not a matter of prompting. The model is handed
    # a description of each case - the method, the origin, the outcome kind, the
    # parameter names - and never a pinned value, a snapshot, or a record. Its reply
    # is validated against a schema whose only strings are descriptions, and any
    # description that fails validation is discarded in favour of the deterministic
    # name. There is no code path by which a returned string becomes an expected
    # value.
    #
    # The deterministic namer is the default and always sufficient: `--no-llm` is not
    # a degraded mode, it is the normal one.
    class Namer
      MAX_DESCRIPTION = 120

      # What the model is allowed to see. Note what is absent: return_value, error
      # messages, job arguments, attributes, ids.
      Facts = Data.define(:case_id, :origin, :outcome, :method_name, :class_name, :parameters)

      def initialize(target:, enabled: false, client: nil)
        @target = target
        @enabled = enabled
        @client = client
      end

      def enabled?
        @enabled && !@client.nil?
      end

      # Returns { "c001" => "description" }, deterministic names for anything the
      # model did not or could not name.
      def describe(cases)
        facts = cases.map { |input_case, observation| facts_for(input_case, observation) }
        fallback = facts.to_h { |fact| [fact.case_id, deterministic(fact)] }

        return fallback unless enabled?

        improved = request(facts)
        fallback.merge(sanitize(improved, fallback))
      rescue StandardError
        # A naming service being down is not a reason to fail a pin.
        fallback
      end

      # What gets sent. Public so a spec can assert that no value can reach it.
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

      # The name pinspec uses when there is no model, which is most of the time.
      def deterministic(fact)
        verb = fact.outcome == :raises ? "raises" : "returns the pinned value"

        "#{fact.method_name} #{verb} (#{fact.case_id}, #{fact.origin})"
      end

      def request(facts)
        response = @client.call(payload(facts))

        parsed = response.is_a?(String) ? JSON.parse(response) : response
        Array(parsed["cases"]).to_h { |entry| [entry["id"], entry["description"]] }
      end

      # Anything that is not a short, plain description is dropped. This is the
      # second wall: even a model that ignored every instruction cannot get a value
      # into a spec, because a value-shaped string does not survive here.
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

      # A description has no business containing a literal, a hash rocket, or a
      # serializer tag. If it does, it is trying to be a value.
      def suspicious?(text)
        return true if text.match?(/=>|\{"t"|\bexpect\b|\beq\(/)
        return true if text.match?(/\d{3,}/)          # an id or a total
        return true if text.count('"') > 2

        false
      end
    end
  end
end
