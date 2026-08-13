# frozen_string_literal: true

require "fileutils"

module Pinspec
  module Validate
    # M-11. Grades each aspect of a pin independently, which is the whole point: a
    # mutation that deletes a `perform_later` should be killed by the job pin even
    # when the return pin sleeps through it.
    #
    # The mechanism comes from the M-11 spike: the backend takes FILES, not example
    # filters, so each aspect is written to its own scratch spec and scored in its
    # own run. The spike measured exactly this - a return-only run scored 60% and its
    # survivors included the deleted side-effect line, which the job-only run killed.
    class PinScorer
      ASPECTS = %i[return error jobs mail].freeze
      SCRATCH_DIR = "tmp/pinspec/aspects"

      # Below these a pin is not worth the confidence it implies.
      STRONG = 80.0
      WEAK = 40.0

      Score = Data.define(:aspect, :score, :verdict, :killed, :survived, :survivors, :note) do
        def strong?
          verdict == :strong
        end
      end

      Report = Data.define(:subject, :scores, :skipped) do
        def scored
          scores.reject { |score| score.score.nil? }
        end

        def strong_ratio
          return 0.0 if scored.empty?

          (scored.count(&:strong?).to_f / scored.size * 100).round(1)
        end

        # The honest measure of what the pin as a whole misses. Aspects are graded
        # separately because they are blind to different things - the return pin does
        # not notice a deleted perform_later, and the job pin does not notice the
        # arithmetic - so a mutant that survives ONE aspect may be caught by another.
        # Only a mutant that survives every aspect is a real gap.
        def surviving_all_aspects
          sets = scored.map { |score| score.survivors.map { |s| mutant_key(s) } }
          return [] if sets.empty? || sets.any?(&:empty?)

          shared = sets.reduce(:&)
          scored.first.survivors.select { |s| shared.include?(mutant_key(s)) }
        end

        # A mutant that one aspect caught: not a gap, just a division of labour.
        def covered_by_another_aspect
          all = scored.flat_map(&:survivors)
          gaps = surviving_all_aspects.map { |s| mutant_key(s) }

          all.reject { |s| gaps.include?(mutant_key(s)) }
             .uniq { |s| mutant_key(s) }
        end

        def mutant_key(survivor)
          [survivor["operator"], survivor["line"], survivor["token"]].join(":")
        end
      end

      WRAPPER = "tmp/pinspec/run_suite.sh"

      def initialize(app_root:, target:, plan:, corpus:, stability:, fk_map:, env: {}, test_command: nil)
        @app_root = app_root
        @target = target
        @plan = plan
        @corpus = corpus
        @stability = stability
        @fk_map = fk_map
        @env = env
        @test_command = test_command
      end

      def run
        MutationAdapter.refuse_unless_available!
        @command = @test_command || generate_wrapper

        scores = present_aspects.map { |aspect| score_aspect(aspect) }

        Report.new(subject: @target.qualified_name, scores: scores, skipped: excluded_aspects)
      end

      private

      # Only the aspects this pin actually asserts. Scoring an absent aspect would
      # produce a vacuous 100%.
      def present_aspects
        found = []

        @stability.stable.each do |verdict|
          observation = verdict.observation
          found << (observation["status"] == "raised" ? :error : :return)
          found << :jobs unless observation["enqueued_jobs"].to_a.empty?
          found << :mail unless observation["mail_deliveries"].to_a.empty?
        end

        found.uniq & ASPECTS
      end

      def excluded_aspects
        ASPECTS - present_aspects
      end

      def score_aspect(aspect)
        spec = write_variant(aspect)

        outcome = MutationAdapter.new(
          source_path: @target.file_path, subject: @target.qualified_name,
          cwd: @app_root, test_command: @command
        ).score(spec)

        return Score.new(aspect: aspect, score: nil, verdict: :unscored, killed: nil,
                         survived: nil, survivors: [], note: outcome.raw) unless outcome.scored?

        Score.new(
          aspect: aspect, score: outcome.score, verdict: verdict_for(aspect, outcome.score),
          killed: outcome.killed, survived: outcome.survived, survivors: outcome.survivors,
          note: caveat_for(aspect)
        )
      end

      # A pin containing {"t":"seq"} or a truncated value asserts less than it
      # appears to, so it cannot be called strong however well it scores (spec v0.3
      # section 14).
      def verdict_for(aspect, score)
        return :weak if score >= STRONG && understated?(aspect)
        return :strong if score >= STRONG
        return :weak if score >= WEAK

        :worthless
      end

      def understated?(aspect)
        @stability.stable.any? do |verdict|
          rendered = verdict.observation.to_s

          rendered.include?('"seq"') || rendered.include?('"truncated"')
        end && %i[return error].include?(aspect)
      end

      def caveat_for(aspect)
        return nil unless understated?(aspect)

        "contains {\"t\":\"seq\"} or a truncated value, so it asserts less than a " \
          "score alone suggests and is not counted as strong"
      end

      # The spike's finding: the backend scrubs Ruby PATH pins, so the test command
      # has to establish the app's runtime itself rather than inherit one. When the
      # app runs on its own Ruby, that means a wrapper - which is exactly what
      # `bundle exec rspec` already is for an app on the default Ruby.
      def generate_wrapper
        return "bundle exec rspec %{files}" if @env.empty?

        path = File.join(@app_root, WRAPPER)
        FileUtils.mkdir_p(File.dirname(path))

        exports = @env.map { |key, value| "export #{key}=#{value.to_s.inspect}" }.join("\n")
        File.write(path, <<~SH)
          #!/bin/bash
          # Generated by pinspec. Establishes this application's own runtime, because
          # the mutation backend runs in pinspec's Ruby and scrubs inherited pins.
          #{exports}
          exec bundle exec rspec "$@"
        SH
        FileUtils.chmod(0o755, path)

        "./#{WRAPPER} %{files}"
      end

      def write_variant(aspect)
        FileUtils.mkdir_p(File.join(@app_root, SCRATCH_DIR))

        Emit::SpecWriter.new(
          app_root: @app_root, target: @target, plan: @plan, corpus: @corpus,
          stability: @stability, fk_map: @fk_map, force: true,
          only_aspect: aspect, spec_dir: SCRATCH_DIR
        ).write!.spec_path
      end
    end
  end
end
