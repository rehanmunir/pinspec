# frozen_string_literal: true

require "prism"
require "yaml"

module Pinspec
  module Analyzer
    class AppProfileReader
      include Source

      RAILS_FLOOR = "6.0"

      FLOOR_APIS = [
        "insert_all - importing a sampled row without firing validations or callbacks",
        "connects_to - detecting a second writing database",
        "ActiveSupport::CurrentAttributes#reset_all - clearing state between cases"
      ].freeze

      HELPER_PATHS = [
        "spec/rails_helper.rb",
        "spec/spec_helper.rb",
        "spec/support/**/*.rb",
        "test/test_helper.rb",
        "config/environments/test.rb"
      ].freeze

      MODEL_GLOB = "app/models/**/*.rb"

      MODEL_MACROS = {
        after_commit:         :after_commit,
        after_create_commit:  :after_commit,
        after_update_commit:  :after_commit,
        after_destroy_commit: :after_commit,
        after_save_commit:    :after_commit,
        default_scope:        :default_scope,
        acts_as_tenant:       :acts_as_tenant,
        has_paper_trail:      :paper_trail,
        has_one_attached:     :active_storage,
        has_many_attached:    :active_storage,
        mount_uploader:       :carrierwave,
        has_attached_file:    :paperclip,
        connects_to:          :connects_to,
        acts_as_paranoid:     :paranoia
      }.freeze

      CURRENT_ATTRIBUTES_BASE = "ActiveSupport::CurrentAttributes"

      class << self
        def read(app_root = ".", enforce_floor: true)
          new(app_root).read(enforce_floor: enforce_floor)
        end
      end

      def initialize(app_root)
        @root = app_root
      end

      def read(enforce_floor: true)
        @notes    = []
        @findings = []

        gems = read_gemfile_lock
        scan_models
        rails_version = version_of(gems, "rails") || version_of(gems, "activerecord")
        floor_ok      = floor_ok?(rails_version)

        enforce_floor!(rails_version) if enforce_floor && floor_ok == false

        AppProfile.new(
          rails_version:          rails_version,
          ruby_version:           @ruby_version,
          rails_floor_ok:         floor_ok,
          auth:                   auth_for(gems),
          authz:                  authz_for(gems),
          tenancy:                tenancy_for(gems),
          soft_delete:            soft_delete_for(gems),
          versioning:             gem?(gems, "paper_trail") ? :paper_trail : :none,
          flags:                  gem?(gems, "flipper") ? :flipper : :none,
          attachments:            attachments_for(gems),
          multi_db:               multi_db?,
          spring:                 gem?(gems, "spring"),
          model_findings:         @findings,
          default_locale:         detect_locale,
          default_zone:           detect_zone,
          db_cleaner:             detect_db_cleaner_strategy(gems),
          transactional_fixtures: detect_transactional_fixtures,
          queue_adapter_in_tests: detect_queue_adapter,
          test_stack:             test_stack_for(gems),
          schema:                 SchemaReader.read(@root),
          factories:              FactoryRegistry.read(@root),
          notes:                  @notes
        )
      end

      private

      def read_gemfile_lock
        path = File.join(@root, "Gemfile.lock")

        unless File.file?(path)
          note(:no_gemfile_lock,
               "no Gemfile.lock at #{path}; every gem answer below is 'not found', " \
               "which is not the same as 'not used'")
          return {}
        end

        gems = {}

        Source.read(path).each_line do |line|
          if (spec = line.match(/^ {4}([a-zA-Z0-9._-]+) \(([^)]+)\)$/))
            gems[spec[1]] = spec[2]
          elsif (ruby = line.match(/^ {3}ruby ([\d.]+)/))
            @ruby_version = ruby[1]
          end
        end

        @ruby_version ||= ruby_version_file
        gems
      end

      def ruby_version_file
        path = File.join(@root, ".ruby-version")
        return nil unless File.file?(path)

        Source.read(path).strip[/\d+\.\d+(\.\d+)?/]
      end

      def gem?(gems, name)
        gems.key?(name) || gems.keys.any? { |key| key == "#{name}-rails" || key.start_with?("#{name}-") }
      end

      def version_of(gems, name)
        gems[name]
      end

      def floor_ok?(rails_version)
        return nil if rails_version.nil?

        Gem::Version.new(rails_version) >= Gem::Version.new(RAILS_FLOOR)
      rescue ArgumentError
        note(:unparseable_rails_version,
             "could not read #{rails_version.inspect} as a version, so the Rails " \
             "#{RAILS_FLOOR} floor was not checked")
        nil
      end

      def enforce_floor!(rails_version)
        raise UnsupportedRailsVersion,
              "this app is on Rails #{rails_version}; pinspec needs #{RAILS_FLOOR} or " \
              "newer. Missing pieces it depends on:\n  - #{FLOOR_APIS.join("\n  - ")}"
      end

      def auth_for(gems)
        return :devise if gem?(gems, "devise")
        return :current_attributes if @findings.any? { |f| f.kind == :current_attributes }

        :none
      end

      def authz_for(gems)
        return :pundit if gem?(gems, "pundit")
        return :cancancan if gem?(gems, "cancancan")

        :none
      end

      def tenancy_for(gems)
        return :apartment if gem?(gems, "ros-apartment") || gem?(gems, "apartment")
        return :acts_as_tenant if gem?(gems, "acts_as_tenant")

        :none
      end

      def soft_delete_for(gems)
        return :paranoia if gem?(gems, "paranoia")
        return :discard if gem?(gems, "discard")

        :none
      end

      def attachments_for(gems)
        found = []
        found << :active_storage if @findings.any? { |f| f.kind == :active_storage } || active_storage_configured?
        found << :carrierwave if gem?(gems, "carrierwave")
        found << :paperclip if gem?(gems, "paperclip")
        found
      end

      def active_storage_configured?
        config_sources.any? { |source| source.match?(/config\.active_storage/) }
      end

      def test_stack_for(gems)
        TestStack.new(
          framework:            detect_framework(gems),
          webmock:              gem?(gems, "webmock"),
          vcr:                  gem?(gems, "vcr"),
          snapshot_backends:    %w[insta approvals].select { |name| gem?(gems, name) }.map(&:to_sym),
          database_cleaner_gem: gem?(gems, "database_cleaner")
        )
      end

      def detect_framework(gems)
        return :rspec if gem?(gems, "rspec-rails") || File.file?(File.join(@root, "spec/rails_helper.rb"))
        return :minitest if File.file?(File.join(@root, "test/test_helper.rb"))

        :none
      end

      def detect_locale
        found = config_sources.filter_map { |source| source[/config\.i18n\.default_locale\s*=\s*:(\w+)/, 1] }.last
        (found || "en").to_sym
      end

      def detect_zone
        config_sources.filter_map { |source| source[/config\.time_zone\s*=\s*["']([^"']+)["']/, 1] }.last || "UTC"
      end

      def config_sources
        @config_sources ||= ["config/application.rb", "config/environments/test.rb"]
                            .map { |relative| File.join(@root, relative) }
                            .select { |path| File.file?(path) }
                            .map { |path| Source.read(path) }
      end

      def helper_sources
        @helper_sources ||= HELPER_PATHS
                            .flat_map { |pattern| Dir[File.join(@root, pattern)] }
                            .select { |path| File.file?(path) }
                            .sort
                            .map { |path| [path, Source.read(path)] }
      end

      def detect_db_cleaner_strategy(gems)
        strategies = helper_sources.flat_map do |_path, source|
          source.scan(/DatabaseCleaner(?:\[[^\]]*\])?\.strategy\s*=\s*\[?:(\w+)/).flatten
        end.uniq

        return :none if strategies.empty? && !gem?(gems, "database_cleaner")
        return :none if strategies.empty?

        if strategies.size > 1
          note(:multiple_db_cleaner_strategies,
               "rails_helper sets more than one DatabaseCleaner strategy " \
               "(#{strategies.join(', ')}); pinspec assumes the first is the default")
        end

        strategies.first.to_sym
      end

      def detect_transactional_fixtures
        helper_sources.each do |_path, source|
          match = source[/use_transactional_(?:fixtures|tests)\s*=\s*(true|false)/, 1]
          return match == "true" unless match.nil?
        end

        nil
      end

      def detect_queue_adapter
        (helper_sources.map(&:last) + config_sources).each do |source|
          match = source[/queue_adapter\s*=\s*:(\w+)/, 1]
          return match.to_sym unless match.nil?
        end

        nil
      end

      def multi_db?
        return true if @findings.any? { |f| f.kind == :connects_to }

        path = File.join(@root, "config", "database.yml")
        return false unless File.file?(path)

        data = load_database_yml(path)
        return false unless data.is_a?(Hash)

        data.each_value.any? { |env| multiple_writers?(env) }
      end

      def load_database_yml(path)
        stripped = Source.read(path).gsub(/<%=?.*?%>/m, "erb")
        YAML.safe_load(stripped, aliases: true, permitted_classes: [Symbol])
      rescue StandardError => e
        note(:unreadable_database_yml,
             "could not parse config/database.yml (#{e.class}); multi-database " \
             "detection falls back to connects_to only")
        nil
      end

      def multiple_writers?(env)
        return false unless env.is_a?(Hash)

        nested = env.values.grep(Hash)
        nested.reject { |config| config["replica"] }.size > 1
      end

      def scan_models
        Dir[File.join(@root, MODEL_GLOB)].sort.each do |path|
          result = Prism.parse(Source.read(path))

          unless result.success?
            next note(:unparsable_model, "#{path} is not valid Ruby; its macros were not scanned")
          end

          walk_classes(result.value.statements, nil, path)
        end
      end

      def walk_classes(statements, prefix, path)
        Array(statements&.body).each do |node|
          next unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

          name = [prefix, node.constant_path.slice].compact.join("::")

          if node.is_a?(Prism::ClassNode) && node.superclass&.slice == CURRENT_ATTRIBUTES_BASE
            add_finding(:current_attributes, name, path, node.location.start_line)
          end

          scan_macros(node.body, name, path)
          walk_classes(node.body, name, path)
        end
      end

      def scan_macros(body, model, path)
        Array(body&.body).grep(Prism::CallNode).each do |call|
          if call.name == :include
            discard = Array(call.arguments&.arguments).any? { |arg| arg.slice.include?("Discard::Model") }
            add_finding(:discard, model, path, call.location.start_line) if discard
            next
          end

          kind = MODEL_MACROS[call.name]
          add_finding(kind, model, path, call.location.start_line) if kind
        end
      end

      def add_finding(kind, model, path, line)
        @findings << ModelFinding.new(kind: kind, model: model, file: path, line: line)
      end

      def note(kind, detail)
        @notes << { kind: kind, detail: detail }
        nil
      end
    end
  end
end
