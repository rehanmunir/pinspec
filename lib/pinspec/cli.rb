# frozen_string_literal: true

require "thor"

module Pinspec
  class CLI < Thor
    class_option :verbose, type: :boolean, default: false, aliases: "-V",
                           desc: "show the plan id, compared fields and per-case detail"

    def self.exit_on_failure?
      true
    end

    ORDER = %w[pin init analyze validate report plan capture version].freeze

    # Thor sorts the command list alphabetically after building it, which buries the
    # one verb most people want between `init` and `plan`, and gives the two
    # diagnostics equal billing with the product.
    def self.sort_commands!(list)
      list.sort_by! do |usage, _|
        name = usage.to_s.split(/\s+/)[1].to_s
        [ORDER.index(name) || ORDER.size, name]
      end
    end

    desc "version", "Print the pinspec version"
    def version
      puts "pinspec #{Pinspec::VERSION} " \
           "(probe v#{Pinspec::PROBE_VERSION}, serializer v#{Pinspec::SERIALIZER_VERSION})"
    end
    map %w[--version -v] => :version

    desc "init [APP_PATH]", "Write .pinspec.yml so later runs need no flags"
    method_option :force, type: :boolean, default: false, desc: "overwrite an existing .pinspec.yml"
    def init(app_path = ".")
      guarded do
        path = File.join(app_path, Config::FILENAME)

        if File.file?(path) && !options[:force]
          raise ConfigInvalid, "#{path} already exists. Pass --force to overwrite it."
        end

        runtime = Runner::Runtime.for(app_path)
        profile = Analyzer::AppProfileReader.read(app_path)

        # Deliberately NOT the detected environment. Writing the resolved PATH into a
        # committed file bakes in one machine's layout and goes stale the moment the
        # app changes Ruby - and detection re-runs on every invocation anyway. `env`
        # is for what pinspec cannot work out: database credentials, feature flags.
        File.write(path, Config.new(app_path, {
                                      "cases" => Inputs::Corpus::DEFAULT_MAX_CASES,
                                      "boots" => 2
                                    }, path).to_yaml_document)

        row "wrote", path
        row "rails", profile.rails_version || "unknown"
        row "ruby", runtime.ruby_version
        row "runtime", runtime.detected? ? "#{runtime.manager}, detected on each run" : "this shell's Ruby"
        puts

        if runtime.note
          puts runtime.note
          puts
        end

        puts "Now: pinspec pin app/services/your_service.rb"
      end
    end

    desc "plan TARGET", "Diagnostic: the world pinspec would build, without running anything"
    method_option :app, type: :string, default: ".", desc: "target app root"
    method_option :cases, type: :numeric, default: Inputs::Corpus::DEFAULT_MAX_CASES,
                          desc: "max input cases per method"
    def plan(target)
      guarded do
        file, method = Analyzer::TargetParser.split_target(target)
        target_profile = Analyzer::TargetParser.parse(file, method)

        print_profile(target_profile)
        puts

        app_profile = Analyzer::AppProfileReader.read(options[:app])
        setup_plan  = Setup::ContextBuilder.build(target: target_profile, profile: app_profile)
        corpus     = Inputs::Corpus.build(
          target:    target_profile,
          plan:      setup_plan,
          schema:    app_profile.schema,
          max_cases: setting('cases', Inputs::Corpus::DEFAULT_MAX_CASES)
        )

        print_plan(setup_plan)
        puts
        print_corpus(corpus)
      end
    end

    desc "analyze [APP_PATH]", "App profile: schema, factories, auth, tenancy, hazards"
    def analyze(app_path = ".")
      guarded do
        Config.load(app_path)
        profile = Analyzer::AppProfileReader.read(app_path)

        print_app(profile)
        puts
        print_schema(profile.schema)
        puts
        print_factories(profile.factories)
        print_warnings(profile)
      end
    end

    desc "capture TARGET", "Diagnostic: run the probe only, and write observations.json"
    method_option :app, type: :string, default: ".", desc: "target app root"
    method_option :cases, type: :numeric, default: Inputs::Corpus::DEFAULT_MAX_CASES
    method_option :boots, type: :numeric, default: 2,
                          desc: "probe boots; 2 is the default because one process shares warm caches"
    method_option :"compare-sql", type: :boolean, default: false,
                                  desc: "include SQL fingerprints in the stability decision"
    method_option :"app-env", type: :string, repeatable: true, banner: "KEY=VALUE",
                              desc: "environment for the app's own runtime (when it is not this shell's Ruby)"
    method_option :sample, type: :boolean, default: false,
                           desc: "read real rows through a generated read-only script in the app"
    method_option :"no-redact", type: :boolean, default: false,
                               desc: "do NOT rewrite personal data in sampled rows (they land in a committed file)"
    def capture(target)
      guarded do
        file, method = Analyzer::TargetParser.split_target(target)

        result = Runner::Capture.new(
          app_root:    options[:app],
          target:      file,
          method:      method,
          max_cases:   setting('cases', Inputs::Corpus::DEFAULT_MAX_CASES),
          boots:       setting('boots', 2),
          compare_sql: setting('compare-sql', false),
          sandbox_env: app_env,
          sample:      setting('sample', false),
          redact:      !options[:"no-redact"]
        ).run

        print_capture(result)

        raise NothingStableToPin, nothing_stable_message(result.stability) if result.stability.nothing_to_pin?
      end
    end

    desc "pin TARGET", "Capture, emit and verify. TARGET is FILE, FILE#METHOD or a directory"
    method_option :app, type: :string, default: ".", desc: "target app root"
    method_option :cases, type: :numeric, default: Inputs::Corpus::DEFAULT_MAX_CASES
    method_option :boots, type: :numeric, default: 2
    method_option :"verify-level", type: :string, default: "full", enum: %w[full isolated]
    method_option :"skip-verify", type: :boolean, default: false
    method_option :force, type: :boolean, default: false,
                         desc: "overwrite a pin file that has been hand-edited"
    method_option :snapshot, type: :string, default: "inline", enum: %w[inline insta approvals],
                             desc: "snapshot backend"
    method_option :"app-env", type: :string, repeatable: true, banner: "KEY=VALUE",
                              desc: "environment for the app's own runtime (when it is not this shell's Ruby)"
    method_option :sample, type: :boolean, default: false,
                           desc: "read real rows through a generated read-only script in the app"
    method_option :"no-redact", type: :boolean, default: false,
                               desc: "do NOT rewrite personal data in sampled rows (they land in a committed file)"
    def pin(target)
      guarded do
        refuse_unbuilt_backend!
        warn_about_redaction!

        return pin_directory(target) if File.directory?(target)

        pin_one(target)
      end
    end

    no_commands do
      def pin_directory(path)
        files = Batch.targets_in(path)
        raise TargetNotFound, "no .rb files under #{path}" if files.empty?

        puts "pinning #{files.size} file(s) under #{path}"
        puts

        report = Batch.new(files) { |file| pin_one(file, quiet: true) }.run

        print_batch(report, path)

        raise NothingStableToPin,
              "nothing under #{path} could be pinned. Each refusal above says why." unless report.anything_pinned?
      end

      def pin_one(target, quiet: false)
        file, method = Analyzer::TargetParser.split_target(target)

        capture = Runner::Capture.new(
          app_root: options[:app], target: file, method: method,
          max_cases: setting('cases', Inputs::Corpus::DEFAULT_MAX_CASES),
          boots: setting('boots', 2), sandbox_env: app_env,
          sample: setting('sample', false), redact: !options[:"no-redact"]
        ).run

        print_capture(capture) unless quiet
        raise NothingStableToPin, nothing_stable_message(capture.stability) if capture.stability.nothing_to_pin?

        written = Emit::SpecWriter.new(
          app_root: options[:app], target: capture.target, plan: capture.plan,
          corpus: capture.corpus, stability: capture.stability,
          fk_map: Analyzer::AppProfileReader.read(options[:app]).schema.fk_map,
          force: options[:force]
        ).write!

        unless quiet
          puts
          print_written(written)
        end

        if options[:"skip-verify"]
          return Batch::Outcome.new(file: file, target: capture.target.qualified_name, status: :pinned,
                                    detail: "not verified", pinned: written.pinned_cases.size,
                                    spec_path: written.spec_path)
        end

        outcomes = Verify::Verifier.new(
          app_root: options[:app], spec_path: written.spec_path,
          level: setting("verify-level", "full").to_sym, env: app_env,
          captured_tz: capture.plan.env_fingerprint[:tz]
        ).verify

        unless quiet
          puts
          print_verification(outcomes)
        end

        report_path = Report::Summary.new(
          app_root: options[:app], profile: Analyzer::AppProfileReader.read(options[:app]),
          target: capture.target, plan: capture.plan, corpus: capture.corpus,
          stability: capture.stability, written: written, outcomes: outcomes
        ).write!

        unless quiet
          puts
          row "report", report_path
        end

        raise VerifyFailed, verify_failed_message(outcomes) unless outcomes.all?(&:green?)

        Batch::Outcome.new(file: file, target: capture.target.qualified_name, status: :pinned,
                           detail: outcomes.map(&:config).join(", "), pinned: written.pinned_cases.size,
                           spec_path: written.spec_path)
      end
    end

    desc "validate TARGET", "Mutation-score a pin, one aspect at a time"
    method_option :app, type: :string, default: ".", desc: "target app root"
    method_option :cases, type: :numeric, default: Inputs::Corpus::DEFAULT_MAX_CASES
    method_option :"test-command", type: :string,
                                   desc: "run the app's suite in its own runtime (for apps on Ruby < 3.4)"
    method_option :"app-env", type: :string, repeatable: true, banner: "KEY=VALUE",
                              desc: "environment for the app's own runtime"
    def validate(target)
      guarded do
        file, method = Analyzer::TargetParser.split_target(target)

        capture = Runner::Capture.new(
          app_root: options[:app], target: file, method: method,
          max_cases: setting('cases', Inputs::Corpus::DEFAULT_MAX_CASES), sandbox_env: app_env
        ).run

        raise NothingStableToPin, nothing_stable_message(capture.stability) if capture.stability.nothing_to_pin?

        profile = Analyzer::AppProfileReader.read(options[:app])

        report = Validate::PinScorer.new(
          app_root: options[:app], target: capture.target, plan: capture.plan,
          corpus: capture.corpus, stability: capture.stability,
          fk_map: profile.schema.fk_map,
          env: app_env, test_command: setting("test-command", nil)
        ).run

        print_scores(report)

        summary = Report::Summary.new(
          app_root: options[:app], profile: profile, target: capture.target,
          plan: capture.plan, corpus: capture.corpus, stability: capture.stability,
          scores: report
        )

        puts
        puts "  report         #{summary.write!}"
      end
    end

    desc "report", "Print the last run's markdown report"
    method_option :app, type: :string, default: ".", desc: "target app root"
    def report
      guarded do
        path = File.join(options[:app], Report::Summary::OUTPUT)

        unless File.file?(path)
          raise TargetNotFound,
                "no report at #{path}. Run `pinspec pin` first (or `pinspec validate`, " \
                "which adds the mutation scores); either writes one every time."
        end

        puts Analyzer::Source.read(path)
      end
    end

    private

    def config
      @config ||= Config.load(options[:app] || ".")
    end

    # File first, then anything typed on the command line, so a flag always wins.
    def app_env
      typed = Array(options[:"app-env"]).each_with_object({}) do |pair, out|
        key, value = pair.split("=", 2)
        out[key] = value.to_s
      end

      config.env.merge(typed)
    end

    def setting(key, default)
      config.value(key, options[key.to_sym], default)
    end

    def refuse_unbuilt_backend!
      backend = options[:snapshot]
      return if backend.nil? || backend == "inline"

      raise VerifyFailed,
            "the #{backend} snapshot backend is not built yet; only `inline` is. " \
            "Inline snapshots keep the pinned value in the spec file, where a reviewer " \
            "can read it - which is why it is the default. Re-run without --snapshot."
    end

    def warn_about_redaction!
      return unless options[:"no-redact"]

      warn "pinspec: --no-redact means real personal data will be written into a spec " \
           "file that gets committed. Every sampled value is reproduced verbatim."
    end

    def guarded
      yield
    rescue Pinspec::Error => e
      warn "pinspec: #{e.message}"
      warn "  reason: #{e.reason}" if e.respond_to?(:reason)
      exit e.exit_code
    end

    def print_schema(graph)
      heuristic = graph.foreign_keys.select(&:heuristic?)

      puts "schema"
      row "tables", graph.tables.size
      row "columns", graph.tables.sum { |t| t.columns.size }
      row "foreign keys", foreign_key_summary(graph, heuristic)
      row "hazards", graph.skipped_statements.empty? ? "none" : graph.skipped_statements.size

      unless heuristic.empty?
        puts
        puts "  inferred from a column name (no constraint declares these):"
        heuristic.each { |fk| puts "    #{fk.key} -> #{fk.to_table}" }
      end

      return if graph.skipped_statements.empty?

      puts
      puts "  hazards (relevance is decided once a plan exists, in M-05):"
      graph.skipped_statements.each { |statement| puts "    #{statement}" }
    end

    def foreign_key_summary(graph, heuristic)
      return "none" if graph.foreign_keys.empty?
      return graph.foreign_keys.size.to_s if heuristic.empty?

      "#{graph.foreign_keys.size} (#{heuristic.size} inferred)"
    end

    def print_plan(plan)
      puts "setup plan  #{plan.plan_id} (generation #{plan.generation}, isolation #{plan.isolation})"

      plan.steps.each_with_index do |step, index|
        puts format("  %2d. %s", index + 1, step)
      end

      unless plan.bindings.empty?
        puts
        puts "  parameter bindings:"
        plan.bindings.each { |param, ref| puts "    #{param} -> #{ref}" }
      end

      unless plan.notes.empty?
        puts
        puts "  plan notes:"
        plan.notes.each { |note| puts "    #{note[:kind]}: #{note[:detail]}" }
      end

    end

    def print_capture(result)
      stability = result.stability

      puts "capture  #{result.target.qualified_name}"
      row "stable", "#{stability.stable.size} of #{result.corpus.size} cases, over #{stability.runs} boots"

      if verbose?
        row "plan", "#{result.plan.plan_id} (isolation #{result.plan.isolation})"
        row "compared", stability.compared_fields.join(", ")
        row "observations", result.output_path

        unless stability.stable.empty?
          puts
          puts "  stable, and therefore pinnable:"
          stability.stable.each { |verdict| puts "    #{verdict.case_id}  #{summarize(verdict.observation)}" }
        end
      end

      return if stability.unstable.empty?

      puts
      puts "  unstable (each with the first field that differed):"
      stability.unstable.each do |verdict|
        puts "    #{verdict.case_id}  #{verdict.cause}"
        verdict.diff.to_s.lines.each { |line| puts "      #{line.chomp}" } unless verdict.diff.to_s.empty?
      end
    end

    def summarize(observation)
      case observation["status"]
      when "raised" then "raised #{observation.dig('error', 'class')}"
      when "returned"
        parts = ["returned #{observation.dig('return_value', 't')}"]
        jobs = observation["enqueued_jobs"].to_a.size
        mail = observation["mail_deliveries"].to_a.size
        parts << "#{jobs} job(s)" if jobs.positive?
        parts << "#{mail} mail" if mail.positive?
        parts.join(", ")
      else observation["status"]
      end
    end

    def nothing_stable_message(stability)
      histogram = stability.causes.map { |cause, count| "#{count} #{cause}" }.join(", ")

      "no case was stable across #{stability.runs} boots (#{histogram}). " \
        "pinspec will not emit a spec it cannot stand behind."
    end

    def print_written(written)
      puts "emitted  #{written.spec_path}"
      row "pinned", "#{written.pinned_cases.size} case(s): " +
                    written.aspects.reject { |_, count| count.zero? }
                           .map { |aspect, count| "#{count} #{aspect}" }.join(", ")

      written.support_paths.each { |path| row "support", path } if verbose?
    end

    def print_verification(outcomes)
      puts "verify"

      outcomes.each do |outcome|
        row outcome.config.to_s, outcome.green? ? "green (#{outcome.examples} examples)" : "#{outcome.status} - #{outcome.diagnosis}"
        next if outcome.green?

        outcome.detail.to_s.lines.first(12).each { |line| puts "      #{line.chomp}" }
      end
    end

    def verify_failed_message(outcomes)
      failed = outcomes.reject(&:green?)

      "the emitted spec did not run green in #{failed.map { |o| o.config }.join(', ')} " \
        "(#{failed.map { |o| o.diagnosis }.uniq.join(', ')}). The pin was written, but " \
        "pinspec will not claim a spec is green when it is not."
    end

    def print_scores(report)
      puts "mutation score  #{report.subject}"
      row "aspects scored", report.scores.map(&:aspect).join(", ")
      row "strong", "#{report.strong_ratio}% of scored aspects"

      puts
      report.scores.each do |score|
        if score.score.nil?
          row score.aspect.to_s, "not scored - #{score.note.to_s.lines.first.to_s.strip}"
          next
        end

        row score.aspect.to_s, "#{score.score}% #{score.verdict} " \
                               "(#{score.killed} killed, #{score.survived} survived)"
        puts "      caveat: #{score.note}" if score.note
        score.survivors.first(3).each do |survivor|
          puts "      survived: #{survivor['operator']} at line #{survivor['line']} - #{survivor['token']}"
        end
      end

      print_cross_aspect(report)

      return if report.skipped.empty?

      puts
      puts "  not asserted by this pin, so not scored: #{report.skipped.join(', ')}"
    end

    def print_cross_aspect(report)
      return if report.scored.size < 2

      gaps = report.surviving_all_aspects
      covered = report.covered_by_another_aspect

      puts
      unless covered.empty?
        puts "  #{covered.size} mutant(s) survived one aspect but were killed by another,"
        puts "  which is the aspects dividing the work rather than a gap:"
        covered.first(4).each { |m| puts "    #{m['operator']} at line #{m['line']} - #{m['token']}" }
      end

      if gaps.empty?
        puts "  nothing survived every aspect: together, the pins cover this target."
      else
        puts "  #{gaps.size} mutant(s) survived EVERY aspect - the real gap:"
        gaps.each { |m| puts "    #{m['operator']} at line #{m['line']} - #{m['token']}" }
      end
    end

    def print_corpus(corpus)
      puts "input cases  #{corpus.size} (#{corpus.origins.map { |o, n| "#{n} #{o}" }.join(', ')})"

      corpus.cases.each { |input_case| puts "  #{input_case}" }

      puts
      puts "Sampled rows and import clusters need a database. `plan` never opens one;"
      puts "pass --sample to `capture` or `pin` to read real rows through a generated"
      puts "read-only script in the app's own runtime."
    end

    def print_app(profile)
      stack = profile.test_stack

      puts "app"
      row "rails", profile.rails_version || "unknown (no Gemfile.lock)"
      row "ruby", profile.ruby_version || "unknown"
      row "isolation", "#{profile.isolation} (#{profile.isolation_source})"
      row "locale / zone", "#{profile.default_locale.inspect} / #{profile.default_zone.inspect}"
      row "auth / authz", "#{profile.auth} / #{profile.authz}"
      row "tenancy", profile.tenancy
      row "soft delete", profile.soft_delete
      row "versioning", profile.versioning
      row "feature flags", profile.flags
      row "attachments", profile.attachments.empty? ? "none" : profile.attachments.join(", ")
      row "multi-database", profile.multi_db
      row "test stack", test_stack_summary(stack)
      row "queue adapter", profile.queue_adapter_in_tests&.inspect || "unset (Rails default)"

      print_model_findings(profile)
      print_notes(profile)
    end

    def test_stack_summary(stack)
      parts = [stack.framework.to_s]
      parts << "webmock" if stack.webmock
      parts << "vcr" if stack.vcr
      parts << "database_cleaner" if stack.database_cleaner_gem
      parts.concat(stack.snapshot_backends.map(&:to_s))
      parts.join(" + ")
    end

    def print_model_findings(profile)
      return if profile.model_findings.empty?

      puts
      puts "  model hazards:"
      profile.model_findings.group_by(&:kind).each do |kind, findings|
        puts "    #{kind}: #{findings.map { |f| "#{f.model} (#{f.file}:#{f.line})" }.join(', ')}"
      end
    end

    def print_notes(profile)
      return if profile.notes.empty?

      puts
      puts "  could not read:"
      profile.notes.each { |note| puts "    #{note[:kind]}: #{note[:detail]}" }
    end

    def print_warnings(profile)
      warnings = profile.warnings
      return if warnings.empty?

      puts
      puts "warnings"
      warnings.each_with_index do |warning, index|
        puts "  #{index + 1}. #{wrap(warning)}"
      end
    end

    def wrap(text, width: 76, indent: "     ")
      words = text.split(/\s+/)
      lines = words.each_with_object([[]]) do |word, acc|
        if (acc.last + [word]).join(" ").length > width
          acc << [word]
        else
          acc.last << word
        end
      end

      lines.map { |line| line.join(" ") }.join("\n#{indent}")
    end

    def print_factories(index)
      with_callbacks = index.factories.select(&:fires_callbacks?)
      non_persisting = index.factories.reject(&:persists?)

      puts "factories (#{index.dsl_module})"
      row "factories", index.factories.empty? ? "none found" : index.factories.size
      row "traits", index.factories.sum { |f| f.traits.size }
      row "unreadable", index.skipped.empty? ? "none" : index.skipped.size

      unless with_callbacks.empty?
        puts
        puts "  callbacks fire while the plan builds records, so the probe attributes"
        puts "  them to setup rather than to the target:"
        with_callbacks.each do |factory|
          puts "    #{factory.name}: #{factory.callbacks.map(&:to_s).join(', ')} " \
               "(#{factory.file}:#{factory.callbacks.first.line})"
        end
      end

      unless non_persisting.empty?
        puts
        puts "  these factories never persist a row, so a plan cannot build on them:"
        non_persisting.each do |factory|
          puts "    #{factory.name}: #{factory.hazards.map(&:first).join(', ')}"
        end
      end

      return if index.skipped.empty?

      puts
      puts "  unreadable factory files (pinspec will act as if these factories do not exist):"
      index.skipped.each { |entry| puts "    #{entry[:file]}: #{entry[:kind]} - #{entry[:detail]}" }
    end

    def print_profile(profile)
      start_line, end_line = profile.source_range

      puts profile.qualified_name
      row "file", "#{profile.file_path}:#{start_line}-#{end_line}"
      row "construction", construction_summary(profile)
      row "ctor params", params_summary(profile.initializer_params)
      row "method params", params_summary(profile.params)
      row "visibility", profile.visibility
      row "constants", list(profile.referenced_constants)
      row "clock sites", clock_summary(profile)
    end

    def construction_summary(profile)
      return "#{profile.construction_kind} (no subject needed)" unless profile.needs_subject?

      args = profile.initializer_params.map(&:to_s).join(", ")
      "#{profile.construction_kind}: #{profile.class_name}.new(#{args})"
    end

    def params_summary(params)
      return "(none)" if params.empty?

      params.map do |param|
        hint = param.type_hint ? " [#{param.type_hint}]" : ""
        "#{param}#{hint}"
      end.join(", ")
    end

    def clock_summary(profile)
      return "(none)" unless profile.clock_dependent?

      sites = profile.clock_sites.map { |s| "#{s.call} (line #{s.line})" }.join(", ")
      "#{sites}; reads the process clock, not Time.zone, so pins will be TZ-dependent"
    end

    def list(values)
      values.empty? ? "(none)" : values.join(", ")
    end

    def verbose?
      options[:verbose]
    end

    def row(label, value)
      puts format("  %-14s %s", label, value)
    end

    def print_batch(report, path)
      width = report.outcomes.map { |o| File.basename(o.file).length }.max.to_i

      report.outcomes.each do |outcome|
        name = File.basename(outcome.file).ljust(width)

        puts case outcome.status
             when :pinned  then format("  pinned   %s  %d case(s), verified", name, outcome.pinned)
             when :refused then format("  skipped  %s  %s", name, outcome.detail)
             else               format("  FAILED   %s  %s", name, outcome.detail)
             end
      end

      puts
      row "pinned", "#{report.pinned.size} of #{report.outcomes.size}"
      row "skipped", report.refused.size if report.refused.any?
      row "failed", report.failed.size if report.failed.any?
      row "specs", File.join(options[:app], Emit::SpecWriter::SPEC_DIR) if report.anything_pinned?
    end
  end
end
