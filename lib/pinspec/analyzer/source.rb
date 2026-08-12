# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    # Prism helpers shared by the analyzer modules. Extracted once M-04 became the
    # fourth copy: four identical literal decoders drifting apart is a bug factory,
    # and the decoder in particular is a contract - "record source text, never an
    # evaluated value" only holds if every reader agrees on what that means.
    module Source
      private

      def each_node(node, &block)
        return unless node

        block.call(node)
        node.compact_child_nodes.each { |child| each_node(child, &block) }
      end

      # Keyword arguments of a call, as a symbol-keyed hash of decoded values.
      def keyword_options(args)
        hash = Array(args).grep(Prism::KeywordHashNode).first
        return {} unless hash

        hash.elements.grep(Prism::AssocNode).each_with_object({}) do |assoc, out|
          next unless assoc.key.is_a?(Prism::SymbolNode)

          out[assoc.key.unescaped.to_sym] = decode(assoc.value)
        end
      end

      # Literals become Ruby values; everything else becomes its own source text.
      # Nothing is evaluated - the analyzer never loads target-app code, so a
      # schema default of `-> { "gen_random_uuid()" }` or a factory attribute of
      # `{ rand * 100 }` is a thing to reproduce, not a value to compute.
      def decode(node)
        case node
        when nil                    then nil
        when Prism::TrueNode        then true
        when Prism::FalseNode       then false
        when Prism::NilNode         then nil
        when Prism::IntegerNode     then node.value
        when Prism::FloatNode       then node.value
        when Prism::StringNode      then node.unescaped
        when Prism::SymbolNode      then node.unescaped.to_sym
        when Prism::ArrayNode       then node.elements.map { |element| decode(element) }
        else node.slice
        end
      end

      def camelize(str)
        str.to_s.split("_").map { |part| part.sub(/\A[a-z]/, &:upcase) }.join
      end
    end
  end
end
