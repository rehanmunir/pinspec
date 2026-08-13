# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    class FactoryRegistry
      include Source

      SEARCH_PATHS = [
        "spec/factories.rb",
        "spec/factories/**/*.rb",
        "test/factories.rb",
        "test/factories/**/*.rb"
      ].freeze

      DSL_MODULES = %w[FactoryBot FactoryGirl Factory].freeze
      LEGACY_MODULES = %w[FactoryGirl Factory].freeze

      CALLBACK_HOOKS = %i[after before].freeze
      CALLBACK_STAGES = %i[build create stub].freeze

      HAZARD_CALLS = %i[skip_create initialize_with to_create].freeze

      BARE_NON_ATTRIBUTES = (HAZARD_CALLS + %i[sequence]).freeze

      STRUCTURAL_CALLS = %i[trait factory transient association sequence].freeze

      class << self
        def read(app_root = ".")
          new(app_root).read
        end

        def parse(path)
          new(File.dirname(path)).parse_files([path])
        end
      end

      def initialize(app_root)
        @app_root = app_root
      end

      def read
        parse_files(factory_files)
      end

      def parse_files(paths)
        @factories  = []
        @skipped    = []
        @legacy_dsl = false

        paths.each { |path| parse_file(path) }
        resolve_models

        FactoryIndex.new(
          factories:  @factories,
          legacy_dsl: @legacy_dsl,
          skipped:    @skipped
        )
      end

      def factory_files
        SEARCH_PATHS
          .flat_map { |pattern| Dir[File.join(@app_root, pattern)] }
          .select { |path| File.file?(path) }
          .uniq
          .sort
      end

      private

      def parse_file(path)
        result = Prism.parse(Source.read(path))

        unless result.success?
          first = result.errors.first
          return skip(path, :unparsable, "#{first.message} (line #{first.location.start_line})")
        end

        found_define = false

        each_node(result.value) do |node|
          next unless node.is_a?(Prism::CallNode) && node.name == :define

          receiver = node.receiver&.slice
          next unless DSL_MODULES.include?(receiver)

          found_define = true
          @legacy_dsl ||= LEGACY_MODULES.include?(receiver)
          visit_scope(node.block, path, nil)
        end

        return if found_define

        top_level = top_level_factories(result.value, path)
        skip(path, :no_factories, "no #{DSL_MODULES.join('/')}.define block") if top_level.zero?
      end

      def top_level_factories(root, path)
        count = 0

        Array(root.statements&.body).each do |node|
          next unless node.is_a?(Prism::CallNode) && node.name == :factory

          visit_factory(node, path, nil)
          count += 1
        end

        count
      end

      def visit_scope(block, path, parent)
        Array(block&.body&.body).each do |node|
          next unless node.is_a?(Prism::CallNode)
          next unless node.name == :factory

          visit_factory(node, path, parent)
        end
      end

      def visit_factory(node, path, parent)
        args    = Array(node.arguments&.arguments)
        name    = decode(args.first)&.to_sym
        return unless name

        options = keyword_options(args)

        factory = Factory.new(
          name:       name,
          model:      options[:class]&.to_s,
          parent:     (options[:parent]&.to_sym || parent&.name),
          aliases:    Array(options[:aliases]).map(&:to_sym),
          attributes: [],
          traits:     [],
          callbacks:  [],
          hazards:    [],
          file:       path,
          line:       node.location.start_line
        )

        slot = @factories.size
        @factories << factory
        @factories[slot] = factory.with(**collect_body(node.block, path, factory))
      end

      def collect_body(block, path, factory)
        attributes = []
        traits     = []
        callbacks  = []
        hazards    = []

        Array(block&.body&.body).each do |node|
          next unless node.is_a?(Prism::CallNode)

          case node.name
          when :factory
            visit_factory(node, path, factory)
          when :trait
            traits << build_trait(node)
          when :transient
            attributes.concat(attributes_in(node.block, kind: :transient))
          when *CALLBACK_HOOKS
            callback = build_callback(node)
            callback ? callbacks << callback : attributes << build_attribute(node)
          when *HAZARD_CALLS
            hazards << [node.name, node.location.start_line]
          else
            attributes << build_attribute(node)
          end
        end

        { attributes: attributes.compact, traits: traits, callbacks: callbacks, hazards: hazards }
      end

      def build_trait(node)
        FactoryTrait.new(
          name:       decode(Array(node.arguments&.arguments).first)&.to_sym,
          attributes: attributes_in(node.block),
          line:       node.location.start_line
        )
      end

      def attributes_in(block, kind: nil)
        Array(block&.body&.body).filter_map do |node|
          next unless node.is_a?(Prism::CallNode)

          attribute = build_attribute(node)
          next unless attribute
          next attribute if kind.nil?

          attribute.with(kind: kind)
        end
      end

      def build_attribute(node)
        args = Array(node.arguments&.arguments)

        case node.name
        when :association
          name = decode(args.first)&.to_sym
          return nil unless name

          attribute(name, :association, node, factory: keyword_options(args)[:factory]&.to_sym, source: nil)
        when :sequence
          name = decode(args.first)&.to_sym
          return nil unless name

          attribute(name, :sequence, node)
        else
          classify_plain(node, args)
        end
      end

      def classify_plain(node, args)
        return nil unless node.receiver.nil?
        return nil if BARE_NON_ATTRIBUTES.include?(node.name)
        return nil if STRUCTURAL_CALLS.include?(node.name)

        if node.block
          attribute(node.name, :block, node)
        elsif args.empty?
          attribute(node.name, :association, node)
        elsif args.all? { |arg| arg.is_a?(Prism::KeywordHashNode) }
          attribute(node.name, :association, node, factory: keyword_options(args)[:factory]&.to_sym)
        else
          attribute(node.name, :static, node)
        end
      end

      def attribute(name, kind, node, factory: nil, source: :from_node)
        FactoryAttribute.new(
          name:    name.to_sym,
          kind:    kind,
          source:  source == :from_node ? attribute_source(node) : source,
          factory: factory,
          line:    node.location.start_line
        )
      end

      def attribute_source(node)
        if node.block
          node.block.body&.slice
        else
          args = Array(node.arguments&.arguments).reject { |a| a.is_a?(Prism::KeywordHashNode) }
          args.empty? ? nil : args.map(&:slice).join(", ")
        end
      end

      def build_callback(node)
        stage = decode(Array(node.arguments&.arguments).first)
        return nil unless stage.is_a?(Symbol) && CALLBACK_STAGES.include?(stage)

        FactoryCallback.new(hook: node.name, stage: stage, line: node.location.start_line)
      end

      def resolve_models
        by_name = {}
        @factories.each do |factory|
          by_name[factory.name] = factory
          factory.aliases.each { |name| by_name[name] ||= factory }
        end

        @factories = @factories.map do |factory|
          next factory if factory.model

          declared = nil
          root     = factory
          seen     = []
          current  = factory

          while current && !seen.include?(current.name)
            seen << current.name
            declared ||= current.model
            root = current
            current = current.parent && by_name[current.parent]
          end

          factory.with(model: declared || camelize(root.name.to_s))
        end
      end

      def skip(path, kind, detail)
        @skipped << { file: path, kind: kind, detail: detail }
      end

    end
  end
end
