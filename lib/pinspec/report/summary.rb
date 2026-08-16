# frozen_string_literal: true

require "fileutils"

module Pinspec
  module Report
    class Summary
      OUTPUT = "tmp/pinspec/report.md"

      def initialize(app_root:, profile:, target: nil, plan: nil, corpus: nil, stability: nil,
                     written: nil, outcomes: nil, scores: nil)
        @app_root = app_root
        @profile = profile
        @target = target
        @plan = plan
        @corpus = corpus
        @stability = stability
        @written = written
        @outcomes = outcomes
        @scores = scores
      end

      def path
        File.join(@app_root, OUTPUT)
      end

      def write!
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, render)
        path
      end

      def render
        sections = [
          heading,
          verdict,
          what_was_pinned,
          what_was_refused,
          isolation_note,
          coverage_caveats,
          redactions,
          provenance,
          hazards,
          mutation_scores,
          footer
        ]

        sections.compact.join("\n")
      end

      private

      def heading
        <<~MD
          # pinspec characterization report

          **Target:** `#{@target&.qualified_name || '(none)'}`
          **Application:** `#{File.expand_path(@app_root)}`
          **Rails:** #{@profile.rails_version || 'unknown'} | **Ruby:** #{@profile.ruby_version || 'unknown'}
          **Plan:** `#{@plan&.plan_id}` | **Isolation:** #{@plan&.isolation}
          **pinspec:** #{VERSION} (probe v#{PROBE_VERSION}, serializer v#{SERIALIZER_VERSION})

          This report describes behaviour that exists TODAY. Nothing here is a
          judgement that the behaviour is correct: pinspec pins bugs on purpose, so
          that a refactor cannot change them silently.
        MD
      end

      def verdict
        return not_verified if @outcomes.nil?

        rows = @outcomes.map do |outcome|
          state = outcome.green? ? "green" : "**#{outcome.status}** (#{outcome.diagnosis})"

          "| #{outcome.config} | #{state} | #{outcome.examples || '-'} |"
        end

        <<~MD

          ## Verification

          The emitted spec was run in three environments, because one run on the
          machine that captured it proves repeatability rather than portability.

          | configuration | result | examples |
          |---|---|---|
          #{rows.join("\n")}

          - **isolated** - the file alone, as captured.
          - **hostile** - a different timezone, locale and RSpec seed.
          - **neighbored** - the file twice in one process, so accumulated state shows.
        MD
      end

      def not_verified
        <<~MD

          ## Verification

          **Not run in this pass.** This report was written by a command that scores
          pins rather than one that verifies them, so nothing here attests that the
          emitted spec runs green. Run `pinspec pin` for the three-configuration
          matrix.
        MD
      end

      def what_was_pinned
        return nil if @stability.nil?

        lines = @stability.stable.map do |verdict|
          observation = verdict.observation
          outcome = observation["status"] == "raised" ? "raises #{observation.dig('error', 'class')}" : "returns a value"
          jobs = observation["enqueued_jobs"].to_a.size
          mail = observation["mail_deliveries"].to_a.size
          effects = [jobs.positive? ? "#{jobs} job(s)" : nil, mail.positive? ? "#{mail} mail" : nil].compact

          "- `#{verdict.case_id}` #{outcome}#{effects.empty? ? '' : ", #{effects.join(', ')}"}"
        end

        <<~MD

          ## What was pinned

          #{@stability.stable.size} of #{@corpus&.size} input cases were stable across
          #{@stability.runs} separate probe boots and are therefore pinned.

          #{lines.empty? ? '_Nothing._' : lines.join("\n")}

          #{@written ? "Pinned file: `#{@written.spec_path}`" : "This pass did not write the pin itself; run `pinspec pin` for that."}
        MD
      end

      def what_was_refused
        return nil if @stability.nil? || @stability.unstable.empty?

        lines = @stability.unstable.map do |verdict|
          excerpt = verdict.diff.to_s.lines.first(4).map { |line| "      #{line.chomp}" }.join("\n")

          "- `#{verdict.case_id}` - **#{verdict.cause}**\n#{excerpt}"
        end

        <<~MD

          ## What was NOT pinned

          These cases produced different results on two runs of the same code, so
          pinning them would freeze an accident.

          #{lines.join("\n")}
        MD
      end

      def isolation_note
        return nil if @plan.nil?

        if @plan.isolation == :truncation
          <<~MD

            ## Isolation: truncation

            This suite does not wrap examples in a transaction (#{@profile.isolation_source}),
            so `after_commit` callbacks **do** fire - during the capture and in the
            emitted spec alike. The capture therefore wrote to the test database and
            truncated afterwards.
          MD
        else
          note = @profile.after_commit_models.empty? ? "" : <<~EXTRA

            #{@profile.after_commit_models.size} model(s) declare `after_commit`
            (#{@profile.after_commit_models.map(&:model).uniq.join(', ')}). Under this
            regime those callbacks never fire - not in the capture, and not in the
            emitted spec. pinspec does not fake them, so this is a real and
            documented divergence from production.
          EXTRA

          <<~MD

            ## Isolation: transaction

            Every case ran inside a transaction that was rolled back (#{@profile.isolation_source}).
            #{note}
          MD
        end
      end

      def coverage_caveats
        caveats = []
        caveats << vacuous_caveat
        caveats << seq_caveat
        caveats << truncated_caveat
        caveats << quarantine_caveat
        caveats << clock_caveat
        caveats = caveats.compact

        return nil if caveats.empty?

        <<~MD

          ## Coverage caveats

          Places where a pin asserts less than it appears to.

          #{caveats.map { |caveat| "- #{caveat}" }.join("\n")}
        MD
      end

      # The honest half of pin strength, and the free half. A case that returned an
      # empty collection, wrote no rows, enqueued nothing and sent nothing did run -
      # but almost any change to the target would still satisfy it. Measured on real
      # code, these are exactly the pins that score weak or worthless.
      def vacuous_caveat
        return nil if @stability.nil?

        count = @stability.stable.count { |verdict| vacuous?(verdict.observation) }
        return nil if count.zero?

        "#{count} pinned case(s) observed nothing happening: an empty or absent return " \
          "value, no rows written, no jobs, no mail. The pin holds, but almost any " \
          "change to the target would still satisfy it. Give the target a world with " \
          "something in it - `--sample` reads real rows - before relying on these."
      end

      EMPTY_RETURNS = [[], {}, nil, false, ""].freeze

      def vacuous?(observation)
        return false unless observation["status"] == "returned"
        return false unless observation["enqueued_jobs"].to_a.empty?
        return false unless observation["mail_deliveries"].to_a.empty?
        return false unless observation["db_delta"].to_h.values.all? { |n| n.to_i.zero? }

        EMPTY_RETURNS.include?(Tags.decode(observation["return_value"]))
      rescue StandardError
        false
      end

      def seq_caveat
        count = rendered_observations.scan('"seq"').size
        return nil if count.zero?

        "#{count} value(s) are pinned as `{\"t\":\"seq\"}` - an autoincrement-shaped " \
          "integer that could not be resolved to a record. The pin asserts an integer " \
          "is present and nothing about which one, because sequence values are not " \
          "reproducible."
      end

      def truncated_caveat
        count = rendered_observations.scan('"truncated"').size
        return nil if count.zero?

        "#{count} value(s) were truncated at the serializer's depth limit, so anything " \
          "deeper than that is unpinned."
      end

      def quarantine_caveat
        return nil if @stability.nil?

        quarantined = @stability.unstable.select { |verdict| verdict.cause == :setup_error }
        return nil if quarantined.empty?

        "#{quarantined.size} case(s) could not have a world built for them and were " \
          "dropped rather than pinned."
      end

      def clock_caveat
        return nil unless @target&.clock_dependent?

        sites = @target.clock_sites.map { |site| "`#{site.call}` (line #{site.line})" }.join(", ")

        "The target reads the process clock at #{sites}. `Time.zone` does not govern " \
          "those, so these pins hold only under `TZ=#{@plan&.env_fingerprint&.dig(:tz)}`. " \
          "The emitted spec guards this rather than letting it pass for the wrong reason."
      end

      def redactions
        clusters = import_steps
        redacted = clusters.flat_map { |step| Array(step.payload[:redacted]) }.uniq
        return nil if clusters.empty?

        <<~MD

          ## Personal data

          #{clusters.size} row(s) were imported from a real database. Rewritten
          attributes: #{redacted.empty? ? 'none' : redacted.map { |name| "`#{name}`" }.join(', ')}.

          Rewrites preserve **domain and length** - an email keeps its domain and its
          character count - so a target that routes on a domain or validates a length
          sees the same behaviour it always did. A redactor that changed behaviour
          would be worse than none, because it would look correct.

          Honest limit: read detection scans the target's own file. It cannot see a
          transitive callee, so no warning is not proof of no read.
        MD
      end

      def provenance
        steps = import_steps
        return nil if steps.empty?

        rows = steps.map { |step| "| `#{step.payload[:name]}` | #{step.payload[:model]} | `#{step.payload[:source]}` |" }

        <<~MD

          ## Imported row provenance

          | ref | model | source |
          |---|---|---|
          #{rows.join("\n")}

          Sources are hashed. A spec file committed to a repository does not map its
          fixtures back to production row ids.
        MD
      end

      def hazards
        warnings = @profile.warnings
        return nil if warnings.empty?

        <<~MD

          ## Application hazards

          Found while profiling the application, independently of this target.

          #{warnings.map { |warning| "- #{warning}" }.join("\n\n")}
        MD
      end

      def mutation_scores
        return nil if @scores.nil?

        rows = @scores.scores.map do |score|
          value = score.score.nil? ? "not scored" : "#{score.score}% (#{score.verdict})"

          "| #{score.aspect} | #{value} | #{score.killed || '-'} | #{score.survived || '-'} |"
        end

        gaps = @scores.surviving_all_aspects

        <<~MD

          ## Mutation scores, by aspect

          Each aspect is graded separately because they are blind to different
          things: a return pin does not notice a deleted `perform_later`, and a job
          pin does not notice the arithmetic.

          | aspect | score | killed | survived |
          |---|---|---|---|
          #{rows.join("\n")}

          #{gaps.empty? ? 'No mutant survived every aspect: together, these pins cover the target.' : "#{gaps.size} mutant(s) survived every aspect, which is the real gap:\n" + gaps.map { |m| "- `#{m['operator']}` at line #{m['line']} - `#{m['token']}`" }.join("\n")}
        MD
      end

      def footer
        <<~MD

          ---

          Generated by pinspec #{VERSION}. `pinspec pin` regenerates the pin and this
          report; `pinspec validate` rewrites it with mutation scores. Neither file is
          meant to be edited by hand.
        MD
      end

      def import_steps
        @plan ? @plan.steps_of(:import_record) : []
      end

      def rendered_observations
        return "" if @stability.nil?

        @rendered_observations ||= @stability.stable.map { |verdict| verdict.observation.to_s }.join
      end
    end
  end
end
