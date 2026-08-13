# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    # M-03. Indexes factory_bot / factory_girl definitions into a FactoryIndex.
    #
    # Structure only, and never executed. A factory body is arbitrary Ruby that
    # touches the app's models, so running one would mean booting the app and
    # writing rows before a plan exists. What M-05 actually needs is *which*
    # attributes and associations a factory supplies, and that is in the source.
    #
    # Every block value is therefore recorded as text. `total { rand * 100 }` is
    # "an attribute named total that the factory supplies", which is the fact that
    # decides whether a plan needs to supply it too.
    class FactoryRegistry
      include Source

      # Single-file and directory conventions, spec and minitest layouts.
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

      # Calls that replace or skip persistence. A plan built on one of these
      # creates no row, so they are recorded rather than ignored.
      HAZARD_CALLS = %i[skip_create initialize_with to_create].freeze

      # Bare DSL words that are not implicit associations. Everything else with no
      # arguments and no block is one: `customer` inside a factory means
      # `association :customer`.
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
          # One unreadable factory file must not take the whole index down, but it
          # cannot be silent either: M-05 would conclude the factory is absent.
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

        # Lenient: some suites declare factories without the define wrapper.
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

      # A factory scope: the body of a define block, or of a factory block.
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
          # nil unless `class:` is declared. Inheriting a parent's model needs the
          # whole index, because `parent: :invoice` may name a factory that has not
          # been read yet - resolved in resolve_models below.
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

        # Reserve the slot before descending, so the index stays in declaration
        # order: collect_body appends any nested factory it finds.
        slot = @factories.size
        @factories << factory
        @factories[slot] = factory.with(**collect_body(node.block, path, factory))
      end

      # Returns the parts gathered from a factory body, and recurses into nested
      # factories as a side effect (they are siblings in the index, linked by
      # `parent`, because that is how factory_bot resolves them by name).
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

          # source stays nil: the positional argument is the attribute's own name,
          # not a value, and the factory override is already in `factory`.
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
          # total { 100.0 }
          attribute(node.name, :block, node)
        elsif args.empty?
          # A bare word inside a factory is an implicit association.
          attribute(node.name, :association, node)
        elsif args.all? { |arg| arg.is_a?(Prism::KeywordHashNode) }
          # customer factory: :premium_customer
          attribute(node.name, :association, node, factory: keyword_options(args)[:factory]&.to_sym)
        else
          # Legacy factory_girl static value: `total 100.0`
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

      # The value as written: a block's body, a static literal, or nil for a bare
      # association. Never evaluated.
      def attribute_source(node)
        if node.block
          node.block.body&.slice
        else
          args = Array(node.arguments&.arguments).reject { |a| a.is_a?(Prism::KeywordHashNode) }
          args.empty? ? nil : args.map(&:slice).join(", ")
        end
      end

      # `after(:create)` is a callback whether or not the block is inline; a bare
      # `after { ... }` with no stage is an attribute named "after", which is
      # absurd but not our business to reinterpret.
      def build_callback(node)
        stage = decode(Array(node.arguments&.arguments).first)
        return nil unless stage.is_a?(Symbol) && CALLBACK_STAGES.include?(stage)

        FactoryCallback.new(hook: node.name, stage: stage, line: node.location.start_line)
      end

      # Second pass. A factory with no `class:` of its own takes the nearest
      # declared class up its parent chain, and failing that the camelized name of
      # the chain's root: `factory :paid_invoice` under `factory :invoice` is an
      # Invoice, and so is `factory :discounted_invoice, parent: :invoice`, whether
      # or not it is lexically nested.
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
