# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    class Discovery
      CONVENTIONAL = %w[call perform run execute process].freeze

      # Never a target: these are object protocol, not behaviour anyone pins.
      NON_TARGETS = %w[initialize to_s to_str inspect hash eql? == <=> to_proc].freeze

      # Conversion methods, which are USUALLY protocol but are sometimes the whole
      # public surface of a service object - OFN's AvailablePaymentMethodsService
      # exposes exactly `to_a` and nothing else. Excluding them outright meant such a
      # class had no candidates at all and was refused as ambiguous. They are ranked
      # last instead, so they win only when nothing else is offered.
      LAST_RESORT = %w[to_a to_h each].freeze

      Choice = Data.define(:method_name, :reason, :candidates, :owner) do
        def ambiguous?
          method_name.nil?
        end

        # `def self.call(...)` delegating to `def call` is the commonest service-object
        # idiom in Ruby, and it makes the bare name resolve to two definitions. The
        # instance method is the real entry point, so it is named explicitly rather
        # than left to look ambiguous.
        def descriptor
          owner ? "#{owner}##{method_name}" : method_name
        end
      end

      # `convention` is the method name this application uses most, counted once over
      # the directory being pinned. Hardcoding `call` reads 2% of a codebase whose
      # services are named `perform`.
      def self.convention_for(files)
        counts = Hash.new(0)

        files.each do |file|
          surface = new(file).surface
          surface[:instance].each { |name| counts[name] += 1 }
        end

        best = counts.max_by { |name, count| [count, CONVENTIONAL.index(name) ? 1 : 0] }
        return nil if best.nil? || best.last < 2

        best.first
      end

      def initialize(file_path)
        @file_path = file_path
      end

      def surface
        @surface ||= read_surface
      end

      def choose(convention: nil)
        instance = surface[:instance]
        singleton = surface[:singleton]

        if instance.empty? && singleton.empty?
          return Choice.new(method_name: nil, reason: :no_public_methods, candidates: [], owner: nil)
        end

        preferred = [convention].compact + CONVENTIONAL

        preferred.each do |name|
          return chosen(name, reason_for(name, convention), instance) if instance.include?(name)
        end

        preferred.each do |name|
          return Choice.new(method_name: name, reason: :class_method, candidates: singleton, owner: nil) if singleton.include?(name)
        end

        # A class with exactly one public method has only one thing it can mean.
        return chosen(instance.first, :sole_method, instance) if instance.size == 1

        # Nothing conventional, and what remains is a single conversion method: that is
        # this class's whole public surface, so it is the target.
        ordinary = instance - LAST_RESORT
        conversions = instance & LAST_RESORT
        return chosen(conversions.first, :sole_method, instance) if ordinary.empty? && conversions.size == 1
        return chosen(ordinary.first, :sole_method, instance) if ordinary.size == 1
        return Choice.new(method_name: singleton.first, reason: :sole_method, candidates: singleton, owner: nil) if instance.empty? && singleton.size == 1

        Choice.new(method_name: nil, reason: :ambiguous, candidates: (instance + singleton).first(8), owner: nil)
      end

      private

      # Qualified only when the same name also exists as a class method, which is
      # what makes the bare name look like two definitions.
      def chosen(name, reason, candidates)
        doubled = surface[:singleton].include?(name)

        Choice.new(method_name: name, reason: reason, candidates: candidates,
                   owner: doubled ? surface[:owners][name] : nil)
      end

      def reason_for(name, convention)
        name == convention ? :convention : :conventional_name
      end

      def read_surface
        source = Source.read(@file_path)
        result = Prism.parse(source)
        return { instance: [], singleton: [], owners: {} } unless result.success?

        instance = []
        singleton = []
        owners = {}
        visibility = :public
        class_stack = []

        walk = lambda do |node, in_singleton|
          return if node.nil?

          case node
          when Prism::CallNode
            # `private` on its own switches visibility; `private :foo` names one method.
            visibility = node.name if %i[private protected public].include?(node.name) && node.arguments.nil?
          when Prism::ClassNode
            visibility = :public
            class_stack.push(node.constant_path.slice)
            node.compact_child_nodes.each { |child| walk.call(child, in_singleton) }
            class_stack.pop
            return
          when Prism::ModuleNode
            visibility = :public
          when Prism::SingletonClassNode
            node.compact_child_nodes.each { |child| walk.call(child, true) }
            return
          when Prism::DefNode
            collect(node, in_singleton, visibility, instance, singleton)
            owners[node.name.to_s] ||= class_stack.last unless node.receiver || in_singleton
          end

          node.compact_child_nodes.each { |child| walk.call(child, in_singleton) }
        end

        walk.call(result.value, false)

        { instance: instance.uniq, singleton: singleton.uniq, owners: owners }
      end

      def collect(node, in_singleton, visibility, instance, singleton)
        name = node.name.to_s
        return unless visibility == :public
        return if NON_TARGETS.include?(name)
        return if name.end_with?("=")

        if node.receiver || in_singleton
          singleton << name
        else
          instance << name
        end
      end
    end
  end
end
