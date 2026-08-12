# frozen_string_literal: true

require "thor"

module Pinspec
  # Spec v0.3 §5. Verbs land milestone by milestone; the ones that aren't built
  # yet say which milestone they arrive in rather than pretending to work.
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc "version", "Print the pinspec version"
    def version
      puts "pinspec #{Pinspec::VERSION} " \
           "(probe v#{Pinspec::PROBE_VERSION}, serializer v#{Pinspec::SERIALIZER_VERSION})"
    end
    map %w[--version -v] => :version

    desc "plan FILE#METHOD", "Resolve a target and print its profile (SetupPlan lands in M2)"
    def plan(target)
      guarded do
        file, method = Analyzer::TargetParser.split_target(target)
        print_profile(Analyzer::TargetParser.parse(file, method))
      end
    end

    desc "analyze [APP_PATH]", "App profile: schema, factories, auth, tenancy, hazards"
    def analyze(app_path = ".")
      guarded do
        profile = Analyzer::AppProfileReader.read(app_path)

        print_app(profile)
        puts
        print_schema(profile.schema)
        puts
        print_factories(profile.factories)
        print_warnings(profile)
      end
    end

    desc "capture FILE#METHOD", "Run the probe, write observations.json"
    def capture(_target)
      not_yet("capture", "M3", "needs M-07 ProbeGenerator")
    end

    desc "pin FILE#METHOD", "Plan + capture + emit + verify"
    def pin(_target)
      not_yet("pin", "M4", "needs M-09 SpecWriter and M-13 Verifier")
    end

    desc "validate SPEC_FILE", "Mutation-score existing pins"
    def validate(_spec_file)
      not_yet("validate", "M5", "needs M-11 MutationAdapter")
    end

    desc "report", "Dump the last run's markdown report"
    def report
      not_yet("report", "M5", "needs M-12 Report")
    end

    private

    def guarded
      yield
    rescue Pinspec::Error => e
      warn "pinspec: #{e.message}"
      warn "  reason: #{e.reason}" if e.respond_to?(:reason)
      exit e.exit_code
    end

    def not_yet(verb, milestone, detail)
      warn "pinspec: `#{verb}` is not implemented yet; it lands in #{milestone} (#{detail})."
      exit 1
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

    # Warning text is written as prose and read in a terminal, so it is wrapped
    # here rather than pre-broken in the string.
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
      puts
      puts "SetupPlan generation lands in M2; this is the resolved target only."
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

    def row(label, value)
      puts format("  %-14s %s", label, value)
    end
  end
end
