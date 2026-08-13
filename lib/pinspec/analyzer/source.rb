# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    module Source
      def self.read(path)
        File.read(path, mode: "rb:BOM|UTF-8").scrub
      end

      private

      def read_source(path)
        Source.read(path)
      end

      def each_node(node, &block)
        return unless node

        block.call(node)
        node.compact_child_nodes.each { |child| each_node(child, &block) }
      end

      def keyword_options(args)
        hash = Array(args).grep(Prism::KeywordHashNode).first
        return {} unless hash

        hash.elements.grep(Prism::AssocNode).each_with_object({}) do |assoc, out|
          next unless assoc.key.is_a?(Prism::SymbolNode)

          out[assoc.key.unescaped.to_sym] = decode(assoc.value)
        end
      end

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
