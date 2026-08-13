# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    # Prism helpers shared by the analyzer modules. Extracted once M-04 became the
    # fourth copy: four identical literal decoders drifting apart is a bug factory,
    # and the decoder in particular is a contract - "record source text, never an
    # evaluated value" only holds if every reader agrees on what that means.
    module Source
      # Every file pinspec reads belongs to somebody else, and a real Rails app has
      # non-ASCII in it - translated strings, an accented name in a comment, a
      # currency symbol. Ruby tags `File.read` with the LOCALE's encoding, so on a
      # machine with `LANG` unset that is US-ASCII, and the first `scan` over a UTF-8
      # byte raises `invalid byte sequence in US-ASCII` - a crash whose message names
      # pinspec's regex and says nothing about the file that caused it.
      #
      # This is not a corner case: `LANG` is routinely unset in CI containers, and
      # pinspec's own :hostile verify config runs `LANG=C` on purpose. Found on the
      # first `analyze` of the first real application.
      #
      # `scrub` rather than raise: a stray invalid byte in one comment must not take
      # down a report about 93 tables. Callers get valid UTF-8 or a replacement
      # character, never an exception.
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
