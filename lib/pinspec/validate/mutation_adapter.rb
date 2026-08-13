# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Pinspec
  module Validate
    # M-11's backend boundary. Confirmed by the M-11 spike
    # (docs/spike-m11-mutation-adapter.md): mutineer, MIT and zero runtime
    # dependencies, which is the only licence compatible with adding no gems to a
    # client's Gemfile.
    #
    # Two facts from that spike shape this class. The backend selects a subject by
    # NAME (`--only "InvoiceCalculator#call"`), not by line range - so what gets
    # handed over is TargetProfile#qualified_name. And it requires Ruby >= 3.4 while
    # pinspec's own floor is 3.2, so `--validate` is optional and refuses clearly
    # rather than exploding inside `gem install`.
    class MutationAdapter
      REQUIRED_RUBY = "3.4"

      # Apps below the backend's Ruby floor run their suite as a subprocess in their
      # own runtime instead. Serial, because there is no per-worker DB isolation.
      def self.available?
        Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(REQUIRED_RUBY) &&
          !find_executable.nil?
      end

      def self.find_executable
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "mutineer") }
           .find { |candidate| File.executable?(candidate) }
      end

      def self.refuse_unless_available!
        return if available?

        raise UnsupportedRailsVersion,
              "`--validate` needs the mutineer backend, which requires Ruby >= " \
              "#{REQUIRED_RUBY} (this is #{RUBY_VERSION}) and a `mutineer` on PATH. " \
              "Everything else in pinspec runs on Ruby 3.2 and up; only scoring is " \
              "gated. Install it with `gem install mutineer` on a 3.4+ Ruby."
      end

      Outcome = Data.define(:subject, :score, :killed, :survived, :total, :survivors, :raw) do
        def scored?
          !score.nil?
        end
      end

      # `env` is deliberately NOT the app's environment. The backend runs in
      # pinspec's Ruby - it requires 3.4 while a legacy app may be on 2.6 - and the
      # app's suite runs in the app's runtime via test_command. Handing the app's
      # GEM_HOME to the backend just hides the backend from itself.
      def initialize(source_path:, subject:, cwd: ".", env: {}, test_command: nil)
        @source_path = source_path
        @subject = subject
        @cwd = cwd
        @env = env
        @test_command = test_command
      end

      # Scores one spec file against one subject.
      def score(spec_path)
        args = command_for(spec_path)
        stdout, stderr, status = Open3.capture3(environment, *args, chdir: @cwd)

        parsed = parse(stdout)
        return unscored(stderr.to_s.empty? ? stdout : stderr) if parsed.nil?

        summary = parsed["summary"] || {}

        Outcome.new(
          subject: @subject,
          score: summary["score"],
          killed: summary["killed"],
          survived: summary["survived"],
          total: summary["total"],
          survivors: Array(parsed["survivors"]).map { |s| { "operator" => s["operator"], "line" => s["line"], "token" => s["token"] } },
          raw: status.exitstatus
        )
      end

      private

      def command_for(spec_path)
        base = [
          self.class.find_executable || "mutineer", "run", relative(@source_path),
          "--test", relative(spec_path),
          "--framework", "rspec",
          "--only", @subject,
          "--format", "json",
          # Surgical redefinition needs a shared VM, which a subprocess is not - so
          # an app running in its own runtime gets whole-file reload instead. The two
          # options are not independent, and the backend says so rather than
          # silently producing nonsense.
          "--strategy", @test_command ? "reload" : "redefine"
        ]

        @test_command ? base + ["--test-command", @test_command] : base
      end

      def relative(path)
        path.to_s.sub("#{File.expand_path(@cwd)}/", "").sub("#{@cwd}/", "")
      end

      # Only the bundler variables are dropped, so a `bundle exec` inside the
      # test-command resolves the app's Gemfile rather than pinspec's. GEM_HOME is
      # left alone: it is how the backend finds its own gems.
      def environment
        {
          "BUNDLE_GEMFILE" => nil, "BUNDLE_PATH" => nil, "BUNDLE_BIN_PATH" => nil,
          "BUNDLER_VERSION" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil,
          "RAILS_ENV" => "test", "DISABLE_SPRING" => "1"
        }.merge(@env)
      end

      def parse(stdout)
        json = stdout.to_s.lines.reverse.find { |line| line.strip.start_with?("{") }
        return nil if json.nil?

        JSON.parse(json)
      rescue JSON::ParserError
        nil
      end

      def unscored(detail)
        Outcome.new(subject: @subject, score: nil, killed: nil, survived: nil, total: nil,
                    survivors: [], raw: detail.to_s.lines.last(8).join)
      end
    end
  end
end
