# frozen_string_literal: true

module Pinspec
  module Analyzer
    # A deliberately small inflector that returns *candidates* rather than an
    # answer, because the schema already tells us every real table name.
    #
    # `t.references "person"` becoming "persons" instead of "people" would put a
    # wrong entry in fk_map, and a wrong fk_map entry means the probe rewrites the
    # wrong integer into a ref. Generating candidates and intersecting them with
    # the known table set makes that class of error impossible: if nothing
    # matches, we say so instead of guessing.
    #
    # ActiveSupport is not available here (the CLI never loads the target app),
    # and vendoring an inflection table would be a maintenance liability for no
    # gain over "check what actually exists".
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

      # Words that are already both, so "the stem itself" is a real candidate.
      UNCOUNTABLE = %w[
        data metadata series species information equipment money news
        settings preferences credentials
      ].freeze

      class << self
        # Every plausible table name for an association stem, best guess first.
        # Callers intersect this with the schema's real table names.
        def table_candidates(stem)
          stem = stem.to_s
          return [stem] if stem.empty?

          candidates = []
          candidates << IRREGULAR_PLURALS[stem] if IRREGULAR_PLURALS.key?(stem)
          candidates << stem if UNCOUNTABLE.include?(stem)
          candidates.concat(regular_plurals(stem))
          candidates << stem # already plural, or an uncountable we do not list

          candidates.compact.uniq
        end

        # Every plausible singular for a table name, best guess first. Used to
        # derive the implicit column of `add_foreign_key "orders", "warehouses"`.
        #
        # Callers must check these against columns that actually exist. Both
        # "invoice" and "invoic" are candidates for "invoices" and only one is a
        # word; the schema knows which, and this does not.
        def singular_candidates(table)
          table = table.to_s
          return [table] if table.empty?

          candidates = []
          candidates << IRREGULAR_SINGULARS[table] if IRREGULAR_SINGULARS.key?(table)
          candidates << table if UNCOUNTABLE.include?(table)

          candidates << "#{table[0..-4]}y" if table.end_with?("ies") && table.length > 3
          # Plain -s first: it is right far more often than stripping -es, which
          # only really applies after a sibilant ("statuses" -> "status").
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
