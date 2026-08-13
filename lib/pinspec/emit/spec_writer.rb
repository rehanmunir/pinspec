# frozen_string_literal: true

require "fileutils"
require "json"

module Pinspec
  module Emit
    # M-09. Writes the pin: an RSpec file that freezes what the probe observed,
    # plus the generated support files it needs.
    #
    # The emitted spec controls the same six axes the probe controlled, by the same
    # rules (spec v0.3 §4c). Where the two hosts could disagree, the spec forces the
    # probe's answer rather than inheriting the suite's - most importantly the
    # isolation regime and the queue adapter, either of which would otherwise make
    # a green capture produce a red or vacuous spec.
    class SpecWriter
      SPEC_DIR = "spec/characterization"
      SUPPORT_DIR = "spec/characterization/support"

      SERIALIZER_TEMPLATE = File.expand_path("../../../templates/serializer.rb", __dir__)
      SUPPORT_TEMPLATE = File.expand_path("../../../templates/spec_support.rb", __dir__)
      FACTORY_TEMPLATE = File.expand_path("../../../templates/factory_build.rb", __dir__)

      # Written into the header of every pin so a reader knows what they are looking
      # at, and so re-pinning can recognise its own output (§12.6).
      PROVENANCE = "pinspec:generated"

      Result = Data.define(:spec_path, :support_paths, :pinned_cases, :aspects)

      # `only_aspect` writes a variant containing just one aspect's expectations.
      # M-11 needs that: the mutation backend takes FILES, not example filters, so
      # grading the return pin independently of the job pin means one file each.
      def initialize(app_root:, target:, plan:, corpus:, stability:, fk_map:, force: false,
                     only_aspect: nil, spec_dir: nil, namer: nil)
        @app_root = app_root
        @target = target
        @plan = plan
        @corpus = corpus
        @stability = stability
        @fk_map = fk_map
        @force = force
        @only_aspect = only_aspect
        @spec_dir = spec_dir || SPEC_DIR
        @namer = namer
      end

      def spec_path
        suffix = @only_aspect ? "_#{@only_aspect}" : ""

        File.join(@app_root, @spec_dir, "#{file_stem}#{suffix}_spec.rb")
      end

      def write!
        guard_existing!

        FileUtils.mkdir_p(File.dirname(spec_path))
        FileUtils.mkdir_p(File.join(@app_root, SUPPORT_DIR))

        support = write_support!
        File.write(spec_path, render)

        Result.new(
          spec_path: spec_path, support_paths: support,
          pinned_cases: pinned.map { |verdict| verdict.case_id }, aspects: aspect_counts
        )
      end

      # pinspec may overwrite its own output, and nothing else. A file without the
      # provenance header is someone's own work; a file with it whose body has been
      # edited is someone's own work too, and both need --force to lose (§12.6).
      def guard_existing!
        return unless File.file?(spec_path)

        existing = Analyzer::Source.read(spec_path)
        return if @force

        unless existing.include?(PROVENANCE)
          raise VerifyFailed,
                "#{spec_path} already exists and was not written by pinspec. " \
                "Nothing pinspec did not write is ever overwritten; move it aside " \
                "or pass --force."
        end
      end

      private

      def pinned
        @stability.stable
      end

      def aspect_counts
        counts = { return: 0, error: 0, jobs: 0, mail: 0 }

        pinned.each do |verdict|
          observation = verdict.observation
          counts[:error] += 1 if observation["status"] == "raised"
          counts[:return] += 1 if observation["status"] == "returned"
          counts[:jobs] += 1 unless observation["enqueued_jobs"].to_a.empty?
          counts[:mail] += 1 unless observation["mail_deliveries"].to_a.empty?
        end

        counts
      end

      def write_support!
        paths = {
          "pinspec_serializer.rb" => File.read(SERIALIZER_TEMPLATE),
          "pinspec_support.rb" => File.read(SUPPORT_TEMPLATE),
          "pinspec_factory.rb" => File.read(FACTORY_TEMPLATE)
        }

        paths.map do |name, source|
          path = File.join(@app_root, SUPPORT_DIR, name)
          File.write(path, source)
          path
        end
      end

      def file_stem
        underscore(@target.class_name).tr("/", "_") + "_" + @target.method_name.to_s.gsub(/[^a-z0-9_]/i, "")
      end

      # ------------------------------------------------------------ rendering --

      def render
        [
          header,
          "require \"#{suite_helper}\"",
          "require_relative \"#{support_prefix}support/pinspec_serializer\"",
          "require_relative \"#{support_prefix}support/pinspec_support\"",
          "require_relative \"#{support_prefix}support/pinspec_factory\"",
          "\nRSpec.describe #{@target.class_name}, :pinspec do",
          indent(isolation_hook, 2),
          indent(environment_hook, 2),
          indent(records, 2),
          indent(helpers, 2),
          indent(cases, 2),
          "end"
        ].reject(&:empty?).join("\n")
      end

      # The helper THIS suite has, not the one rspec-rails scaffolds. The
      # rails_helper/spec_helper split is a convention, and plenty of real suites
      # never adopted it: Open Food Network has `spec/spec_helper.rb` and no
      # rails_helper at all, so a hardcoded `require "rails_helper"` produced a spec
      # that could not be loaded - and, because rspec reports a load error as
      # `0 examples, 0 failures`, a verifier that called it green three times.
      def suite_helper
        return @suite_helper if defined?(@suite_helper)

        @suite_helper =
          %w[rails_helper spec_helper test_helper].find do |name|
            File.file?(File.join(@app_root, "spec", "#{name}.rb")) ||
              File.file?(File.join(@app_root, "test", "#{name}.rb"))
          end || "rails_helper"
      end

      # A per-aspect variant is written to a scratch directory, so it has to reach
      # back up to the shared support files rather than beside itself.
      def support_prefix
        @spec_dir == SPEC_DIR ? "" : "#{File.expand_path(File.join(@app_root, SUPPORT_DIR))}/".sub(%r{/support/$}, "/")
      end

      def header
        lines = [
          "# frozen_string_literal: true",
          "#",
          "# #{PROVENANCE} - characterization pin. Do not hand-edit: re-run pinspec.",
          "#",
          "# plan_id:    #{@plan.plan_id}",
          "# serializer: #{SERIALIZER_VERSION}",
          "# isolation:  #{@plan.isolation}",
          "# captured:   #{@stability.runs} boots, #{pinned.size} of #{@corpus.size} cases stable",
          "#",
          "# This file freezes what the code does TODAY. A failure here means the",
          "# behaviour changed - not that the behaviour is correct. Bugs get pinned on",
          "# purpose."
        ]

        lines.concat(clock_warning) if @target.clock_dependent?
        lines.concat(unstable_notes) unless @stability.unstable.empty?
        lines << ""
        lines.join("\n")
      end

      def clock_warning
        sites = @target.clock_sites.map { |site| "#{site.call} (line #{site.line})" }.join(", ")

        [
          "#",
          "# WARNING: the target reads the PROCESS clock at #{sites}.",
          "# Time.zone does not govern those, so these pins are only valid under the",
          "# capture's timezone (TZ=#{@plan.env_fingerprint[:tz]}). The guard below fails",
          "# loudly rather than letting them pass for the wrong reason."
        ]
      end

      def unstable_notes
        lines = ["#", "# Not pinned, because the two capture runs disagreed:"]

        @stability.unstable.each do |verdict|
          lines << "#   #{verdict.case_id}: #{verdict.cause}"
        end

        lines
      end

      # The regime is forced, not inherited. A suite that truncates instead of
      # transacting would fire after_commit callbacks the probe never saw.
      def isolation_hook
        return truncation_note if @plan.isolation == :truncation

        <<~RUBY
          # isolation: transaction. Forced regardless of this suite's own strategy,
          # because the capture ran this way and after_commit callbacks depend on it.
          around do |example|
            ActiveRecord::Base.transaction(requires_new: true) do
              example.run
              raise ActiveRecord::Rollback
            end
          end
        RUBY
      end

      def truncation_note
        <<~RUBY
          # isolation: truncation. This suite does not wrap examples in a transaction,
          # so after_commit callbacks DO fire here - as they did during the capture.
          # These examples mutate the test database.
        RUBY
      end

      def environment_hook
        fingerprint = @plan.env_fingerprint

        <<~RUBY
          before do
          #{clock_guard(fingerprint)}  pinspec_clear_sinks

            travel_to Time.parse(#{PINSPEC_EPOCH.inspect})
            srand(#{PINSPEC_SEED})
            I18n.locale = #{fingerprint[:locale].inspect}
            Time.zone = #{fingerprint[:zone].inspect}
          #{flag_lines}end

          after { travel_back }
        RUBY
      end

      # Only for a target that reads the PROCESS clock. Guarding every pin would
      # mean no pin survives a different timezone, including the great majority
      # that are genuinely timezone-independent.
      def clock_guard(fingerprint)
        return "" unless @target.clock_dependent?

        "  pinspec_guard_env!(#{fingerprint[:tz].to_s.inspect})\n"
      end

      def flag_lines
        flags = @plan.steps_of(:set_flag)
        return "" if flags.empty?

        flags.map do |step|
          state = step.payload[:enabled] ? "enable" : "disable"
          "  Flipper.#{state}(#{step.payload[:flag].inspect})\n"
        end.join
      end

      # Records render as let! so they exist before the subject runs, and as the
      # explicit calls a human would have written.
      def records
        steps = @plan.record_steps
        return "" if steps.empty?

        steps.map { |step| record_line(step) }.join("\n") + "\n"
      end

      def record_line(step)
        payload = step.payload

        if step.kind == :import_record
          return "# imported from #{payload[:source]}\n" \
                 "let!(:#{payload[:name]}) { #{import_call(payload)} }"
        end

        "let!(:#{payload[:name]}) { #{create_call(payload)} }"
      end

      def create_call(payload)
        if payload[:factory]
          # NOT a bare `create(:order)`. A real app's factory can be
          # non-deterministic - OFN's draws FFaker emails its own validation rejects
          # about a third of the time - so the probe retries under the fixed seed. The
          # spec host has to run the SAME loop or it consumes different random values
          # and builds a different record, which reads as a behaviour change.
          return "PinspecFactory.create(:#{payload[:factory]})"
        end

        attrs = (payload[:attrs] || {}).merge(assoc_arguments(payload))
        "#{payload[:model]}.create!(#{render_attrs(attrs)})"
      end

      def import_call(payload)
        attrs = (payload[:attrs] || {}).transform_values { |tagged| Tags.decode(tagged) }

        "#{payload[:model]}.create!(#{render_attrs(attrs)})"
      end

      def assoc_arguments(payload)
        (payload[:assoc_refs] || {}).each_with_object({}) do |(column, ref), out|
          out[column] = RawRuby.new("#{ref}.id")
        end
      end

      def render_attrs(attrs)
        attrs.map { |name, value| "#{name}: #{render_value(value)}" }.join(", ")
      end

      def render_value(value)
        return value.source if value.is_a?(RawRuby)

        canonical_literal(value)
      end

      # Marks a string that is Ruby source, not a Ruby String.
      class RawRuby
        attr_reader :source

        def initialize(source)
          @source = source
        end
      end

      def helpers
        <<~RUBY
          let(:pinspec_records) { { #{ref_pairs} } }
          let(:pinspec_fk_map) { #{canonical_literal(@fk_map)} }
          let(:pinspec_refs_for) { ->(result) { pinspec_refs(pinspec_records, result) } }
        RUBY
      end

      def ref_pairs
        @plan.record_steps.map { |step| "#{step.payload[:name]}: #{step.payload[:name]}" }.join(", ")
      end

      def cases
        pinned.map { |verdict| render_case(verdict) }.join("\n")
      end

      def render_case(verdict)
        input_case = @corpus.cases.find { |c| c.id == verdict.case_id }
        observation = verdict.observation

        <<~RUBY
          describe "#{description_for(input_case, observation)}" do
            #{indent(subject_line(input_case), 2).strip}

          #{indent(expectations(observation), 2)}end
        RUBY
      end

      # Deterministic naming: the --no-llm path, and the default. M-10 may later
      # improve the prose, but it can never touch a value.
      def description_for(input_case, observation)
        named = descriptions[input_case.id]
        return named if named

        outcome =
          case observation["status"]
          when "raised" then "raises #{observation.dig('error', 'class')}"
          else "returns the pinned #{value_shape(observation['return_value'])}"
          end

        "#{@target.method_name} #{outcome} (#{input_case.id}, #{input_case.origin})"
      end

      # Names only, and only when a namer was supplied. The deterministic names
      # above are the default and are always sufficient.
      def descriptions
        return @descriptions if defined?(@descriptions)

        @descriptions =
          if @namer&.enabled?
            pairs = pinned.filter_map do |verdict|
              input_case = @corpus.cases.find { |c| c.id == verdict.case_id }
              [input_case, verdict.observation] if input_case
            end
            @namer.describe(pairs)
          else
            {}
          end
      end

      def value_shape(value)
        case value && value["t"]
        when "record" then "#{value['class']} it creates"
        when "str" then "string"
        when "int", "float", "decimal" then "number"
        when "nil" then "nil"
        when "array", "relation" then "collection"
        else value && value["t"] || "value"
        end
      end

      def subject_line(input_case)
        "subject(:pinned) { #{invocation(input_case)} }"
      end

      def invocation(input_case)
        receiver =
          case @target.construction_kind
          when :class_method then @target.class_name
          when :model_instance then @plan.binding_for(:__subject__) || "subject_record"
          else "#{@target.class_name}.new(#{arguments(input_case.ctor_args, input_case.ctor_kwargs)})"
          end

        arguments = arguments(input_case.args, input_case.kwargs)
        arguments.empty? ? "#{receiver}.#{@target.method_name}" : "#{receiver}.#{@target.method_name}(#{arguments})"
      end

      def arguments(positional, keyword)
        parts = Array(positional).map { |value| ruby_literal(value) }
        parts.concat(Hash(keyword).map { |name, value| "#{name}: #{ruby_literal(value)}" })
        parts.join(", ")
      end

      # A tagged case argument becomes Ruby source. A ref becomes the let! name -
      # never an id, which is the whole point.
      def ruby_literal(tagged)
        return canonical_literal(tagged) unless tagged.is_a?(Hash) && tagged.key?("t")

        case tagged["t"]
        when "ref" then tagged["v"]
        when "decimal" then "BigDecimal(#{tagged['v'].inspect})"
        when "sym" then ":#{tagged['v']}"
        when "nil" then "nil"
        when "date" then "Date.parse(#{tagged['v'].inspect})"
        when "time" then "Time.parse(#{tagged['v'].inspect})"
        when "array" then "[#{tagged['v'].map { |inner| ruby_literal(inner) }.join(', ')}]"
        when "hash" then "{ #{tagged['v'].map { |k, v| "#{ruby_literal(k)} => #{ruby_literal(v)}" }.join(', ')} }"
        else canonical_literal(tagged["v"])
        end
      end

      def expectations(observation)
        parts = []
        raised = observation["status"] == "raised"

        parts << (raised ? error_expectation(observation) : return_expectation(observation)) if
          wants?(raised ? :error : :return)
        parts << jobs_expectation(observation) if wants?(:jobs) && !observation["enqueued_jobs"].to_a.empty?
        parts << mail_expectation(observation) if wants?(:mail) && !observation["mail_deliveries"].to_a.empty?

        # A variant with nothing to assert would pass vacuously and score as a
        # perfect pin, which is the opposite of the truth.
        parts << pending_aspect if parts.empty?

        parts.join("\n")
      end

      def wants?(aspect)
        @only_aspect.nil? || @only_aspect.to_sym == aspect
      end

      def pending_aspect
        <<~RUBY
          it "has no #{@only_aspect} aspect in this case" do
            skip "this case pins nothing on the #{@only_aspect} aspect"
          end
        RUBY
      end

      def return_expectation(observation)
        <<~RUBY
          it "returns the pinned value" do
            # Normalized WITHOUT the returned record in the ref table, because the
            # probe serializes the return value before registering it. The sink
            # expectations below use the table that includes it. Same operations in
            # the same order, in both hosts - which is the whole of section 4c.
            expect(
              PinspecSerializer.normalize(pinned, refs: pinspec_refs(pinspec_records), fk_map: pinspec_fk_map)
            ).to eq(#{snapshot(observation['return_value'])})
          end
        RUBY
      end

      def error_expectation(observation)
        error = observation["error"]

        <<~RUBY
          it "raises the pinned error" do
            expect { pinned }.to raise_error(#{error['class']}, #{error['message'].inspect})
          end
        RUBY
      end

      # Block-scoped: a factory's after(:create) enqueues too, and an assertion that
      # counted setup's jobs would pass for the wrong reason.
      def jobs_expectation(observation)
        <<~RUBY
          it "enqueues the pinned jobs" do
            _result, jobs = pinspec_jobs_from(pinspec_refs_for, pinspec_fk_map) { pinned }

            expect(jobs).to eq(#{snapshot(observation['enqueued_jobs'])})
          end
        RUBY
      end

      def mail_expectation(observation)
        <<~RUBY
          it "delivers the pinned mail" do
            pinspec_clear_sinks
            pinned

            expect(pinspec_deliveries).to eq(#{snapshot(observation['mail_deliveries'])})
          end
        RUBY
      end

      # Stored as a Ruby literal rather than JSON: a reader can see what is pinned,
      # and there is no parse step between the file and the assertion.
      def snapshot(value)
        canonical_literal(JSON.parse(JSON.generate(value)))
      end

      # Ruby 3.4 changed `Hash#inspect` to put spaces around the rocket, so
      # `inspect` renders `{"t" => "int"}` on 3.4 and `{"t"=>"int"}` on 3.3. Both
      # parse to the same value, which is why this went unnoticed until pinspec's own
      # suite ran on two Rubies - but the emitted file is a COMMITTED artifact, and a
      # tool whose promise is "re-run and nothing changes unless behaviour changed"
      # cannot rewrite every pin in the repository because someone upgraded Ruby.
      #
      # So the literal is rendered here rather than delegated. 3.4's spacing is the
      # one chosen: it is the more readable form and it parses on every Ruby pinspec
      # supports. Everything else - String, Integer, Float, Symbol, nil, Array -
      # inspects identically across versions and is delegated.
      def canonical_literal(value)
        case value
        when Hash
          return "{}" if value.empty?

          "{" + value.map { |key, inner| "#{canonical_literal(key)} => #{canonical_literal(inner)}" }.join(", ") + "}"
        when Array
          "[" + value.map { |inner| canonical_literal(inner) }.join(", ") + "]"
        else
          value.inspect
        end
      end

      # -------------------------------------------------------------- plumbing --

      def indent(text, spaces)
        return "" if text.to_s.empty?

        pad = " " * spaces
        text.to_s.lines.map { |line| line.strip.empty? ? line : "#{pad}#{line}" }.join
      end

      def underscore(str)
        str.to_s
           .gsub("::", "/")
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end
    end
  end
end
