# frozen_string_literal: true

require "fileutils"
require "json"

module Pinspec
  module Runner
    # Orchestrates M-07: plan, corpus, probe, two boots, stability, observations.json.
    #
    # Kept out of the CLI so that `capture` and `pin` share one path - a divergence
    # between them would mean the thing that gets verified is not the thing that got
    # captured.
    class Capture
      OUTPUT = "observations.json"

      Result = Data.define(:target, :plan, :corpus, :runs, :stability, :probe_source, :output_path)

      def initialize(app_root:, target:, method:, max_cases: Inputs::Corpus::DEFAULT_MAX_CASES,
                     boots: 2, compare_sql: false, sandbox_env: {}, output_dir: nil,
                     sample: false, sample_env: nil, redact: true)
        @app_root = app_root
        @target_file = target
        @method = method
        @max_cases = max_cases
        @boots = boots
        @compare_sql = compare_sql
        @sandbox_env = sandbox_env
        @output_dir = output_dir || File.join(app_root, Sandbox::PROBE_DIR)
        @sample = sample
        @sample_env = sample_env
        @redact = redact
      end

      def run
        target_profile = Analyzer::TargetParser.parse(@target_file, @method)
        app_profile    = Analyzer::AppProfileReader.read(@app_root)

        # A provisional plan first, to learn which tables the target's world is made
        # of. Sampling needs that answer, and the plan needs the sampled rows - so
        # the plan is built twice rather than either guessing.
        plan = Setup::ContextBuilder.build(target: target_profile, profile: app_profile, tz: probe_tz)
        imports = @sample ? sample_imports(plan, app_profile, target_profile) : []
        if imports.any?
          plan = Setup::ContextBuilder.build(target: target_profile, profile: app_profile,
                                             imports: imports, tz: probe_tz)
        end

        corpus = Inputs::Corpus.build(
          target: target_profile, plan: plan,
          schema: app_profile.schema, max_cases: @max_cases
        )

        probe = ProbeGenerator.generate(
          plan: plan, corpus: corpus,
          fk_map: app_profile.schema.fk_map, target: target_profile
        )

        runs = Sandbox.new(app_root: @app_root, probe_source: probe, env: @sandbox_env)
                      .capture(boots: @boots)

        stability = Emit::StabilityFilter.new(compare_sql: @compare_sql).filter(runs)

        Result.new(
          target: target_profile, plan: plan, corpus: corpus, runs: runs,
          stability: stability, probe_source: probe, output_path: write_observations(plan, runs, stability)
        )
      end

      # What the probe's timezone will actually be: the sandbox forces one, and
      # `--app-env TZ=...` can override it. The plan has to record the effective
      # value, because the emitted spec's clock guard is generated from it and the
      # verifier runs against it.
      def probe_tz
        @sandbox_env["TZ"] || Sandbox::FORCED_ENV.fetch("TZ")
      end

      private

      # Reads real rows through a generated read-only script in the app's own
      # runtime, then hydrates them at plan time. The probe never opens this
      # connection, which is what lets it point at development while the probe runs
      # under RAILS_ENV=test.
      def sample_imports(plan, app_profile, target_profile)
        tables = plan.record_steps.map { |step| app_profile.schema.table(table_of(step, app_profile)) }
                     .compact.map(&:name).uniq
        return [] if tables.empty?

        requests = tables.map do |table|
          { table: table, status_column: status_column_for(app_profile.schema.table(table)), limit: 3 }
        end

        result = Inputs::SampleRunner.new(app_root: @app_root, env: @sample_env || @sandbox_env).fetch(requests)

        return [] if result.empty?

        root = tables.first
        hydrator = Inputs::Hydrator.new(
          schema: app_profile.schema,
          redactor: Inputs::Redactor.new(enabled: @redact),
          factories: app_profile.factories
        )
        clusters, = hydrator.hydrate(root, result.rows_for(root).first(1), result.all_rows,
                                     target_source: Analyzer::Source.read(target_profile.file_path))
        clusters
      end

      def table_of(step, app_profile)
        model = step.payload[:model] || step.payload[:factory].to_s
        Setup::DependencyResolver.new(app_profile.schema, app_profile.factories).table_for(model)&.name ||
          Setup::DependencyResolver.new(app_profile.schema, app_profile.factories).table_for(model.to_s.capitalize)&.name
      end

      # The ubiquitous `case status` service object is the single highest-coverage
      # win available, so a status-like column is stratified when one exists.
      def status_column_for(table)
        return nil if table.nil?

        %w[status state kind].find { |name| table.column(name) }
      end

      def write_observations(plan, runs, stability)
        FileUtils.mkdir_p(@output_dir)
        path = File.join(@output_dir, OUTPUT)

        File.write(path, JSON.pretty_generate(
                           "pinspec_probe_version" => PROBE_VERSION,
                           "serializer" => SERIALIZER_VERSION,
                           "plan_id" => plan.plan_id,
                           "isolation" => plan.isolation.to_s,
                           "runs" => runs.map { |run| { "run" => run.run, "env" => run.env } },
                           "compared_fields" => stability.compared_fields,
                           "stable" => stability.stable.map { |verdict| verdict.case_id },
                           "unstable" => stability.unstable.map do |verdict|
                             { "case_id" => verdict.case_id, "cause" => verdict.cause.to_s, "diff" => verdict.diff }
                           end,
                           "observations" => runs.map do |run|
                             { "run" => run.run, "observations" => run.observations }
                           end
                         ))

        path
      end
    end
  end
end
