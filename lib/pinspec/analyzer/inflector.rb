# frozen_string_literal: true

module Pinspec
  module Analyzer
    module Inflector
      IRREGULAR_PLURALS = {
        "person" => "people",
        "child" => "children",
        "man" => "men",
        "woman" => "women",
        "foot" => "feet",
        "tooth" => "teeth",
        "mouse" => "mice",
        "goose" => "geese",
        "ox" => "oxen",
        "datum" => "data",
        "medium" => "media",
        "criterion" => "criteria",
        "analysis" => "analyses",
        "diagnosis" => "diagnoses",
        "basis" => "bases",
        "index" => "indices",
        "matrix" => "matrices",
        "vertex" => "vertices",
        "status" => "statuses"
      }.freeze

      IRREGULAR_SINGULARS = IRREGULAR_PLURALS.invert.freeze

      UNCOUNTABLE = %w[
        data metadata series species information equipment money news
        settings preferences credentials
      ].freeze

      class << self
        def table_candidates(stem)
          stem = stem.to_s
          return [stem] if stem.empty?

          candidates = []
          candidates << IRREGULAR_PLURALS[stem] if IRREGULAR_PLURALS.key?(stem)
          candidates << stem if UNCOUNTABLE.include?(stem)
          candidates.concat(regular_plurals(stem))
          candidates << stem

          candidates.compact.uniq
        end

        def singular_candidates(table)
          table = table.to_s
          return [table] if table.empty?

          candidates = []
          candidates << IRREGULAR_SINGULARS[table] if IRREGULAR_SINGULARS.key?(table)
          candidates << table if UNCOUNTABLE.include?(table)

          candidates << "#{table[0..-4]}y" if table.end_with?("ies") && table.length > 3
          candidates << table[0..-2] if table.end_with?("s") && !table.end_with?("ss")
          candidates << table[0..-3] if table.end_with?("es") && table.length > 2
          candidates << table

          candidates.compact.uniq
        end

        private

        def regular_plurals(stem)
          out = []

          if stem.match?(/[^aeiou]y\z/)
            out << "#{stem[0..-2]}ies"
          elsif stem.match?(/(s|x|z|ch|sh)\z/)
            out << "#{stem}es"
          elsif stem.match?(/(?:[^f]f|fe)\z/)
            out << "#{stem.sub(/fe?\z/, '')}ves"
            out << "#{stem}s"
          end

          out << "#{stem}s"
          out
        end
      end
    end
  end
end
