# frozen_string_literal: true

require "date"

module Pinspec
  # The serializer-v3 tag vocabulary (spec v0.3 §9), CLI side.
  #
  # Every value crossing the JSON boundary is tagged, including the ones JSON
  # could carry natively. Uniformity is the point: a bare `5` in cases.json would
  # be ambiguous between an Integer and a decimal that happened to be whole, and
  # the probe would have to guess. Guessing is what the tags exist to prevent.
  #
  # This is one half of §4c's encoding axis. M-07's probe encoder and M-09's
  # generated spec helper are built from the same vocabulary, from one template -
  # so the constants here are the contract, not an implementation detail.
  module Tags
    # Tags that carry a value under "v".
    VALUED = %w[int float str sym decimal date time bin ref seq relation cycle inf].freeze

    class << self
      def encode(value)
        case value
        when nil        then { "t" => "nil" }
        when true       then { "t" => "bool", "v" => true }
        when false      then { "t" => "bool", "v" => false }
        when Integer    then { "t" => "int", "v" => value }
        when Float      then encode_float(value)
        when Symbol     then { "t" => "sym", "v" => value.to_s }
        when String     then encode_string(value)
        when Array      then { "t" => "array", "v" => value.map { |element| encode(element) } }
        when Hash       then encode_hash(value)
        when Date       then { "t" => "date", "v" => value.iso8601 }
        else { "t" => "str", "v" => value.to_s }
        end
      end

      # A ref names a record the plan builds. It is never an id: ids come from
      # sequences, and sequences do not roll back (spec v0.3 §12.12).
      def ref(name)
        { "t" => "ref", "v" => name.to_s }
      end

      # A decimal is a string on the wire, always. Floats cannot represent money
      # and a Float round-trip would silently change a pinned total.
      def decimal(value)
        { "t" => "decimal", "v" => value.to_s }
      end

      def tagged?(value)
        value.is_a?(Hash) && value.key?("t")
      end

      def type_of(value)
        tagged?(value) ? value["t"] : nil
      end

      # Round-trips a tagged value back to Ruby. Used by the CLI for reporting and
      # by the specs; the probe has its own decoder generated from the template.
      def decode(tagged)
        return tagged unless tagged?(tagged)

        case tagged["t"]
        when "nil"      then nil
        when "bool"     then tagged["v"]
        when "int"      then tagged["v"]
        when "float"    then tagged["v"]
        when "nan"      then Float::NAN
        when "inf"      then tagged["sign"].to_i.negative? ? -Float::INFINITY : Float::INFINITY
        when "sym"      then tagged["v"].to_sym
        when "str"      then tagged["v"]
        when "decimal"  then tagged["v"]
        when "date"     then tagged["v"]
        when "time"     then tagged["v"]
        when "bin"      then tagged["v"].unpack1("m0").force_encoding(tagged["enc"] || "ASCII-8BIT")
        when "array"    then tagged["v"].map { |element| decode(element) }
        when "hash"     then tagged["v"].to_h { |key, element| [decode(key), decode(element)] }
        when "ref"      then tagged["v"]
        else tagged["v"]
        end
      end

      # A short, human-readable rendering for `pinspec plan` output.
      def describe(tagged)
        return tagged.inspect unless tagged?(tagged)

        case tagged["t"]
        when "nil"   then "nil"
        when "ref"   then tagged["v"]
        when "sym"   then ":#{tagged['v']}"
        when "str"   then tagged["v"].inspect
        when "array" then "[#{tagged['v'].map { |element| describe(element) }.join(', ')}]"
        when "hash"  then "{#{tagged['v'].map { |k, v| "#{describe(k)}=>#{describe(v)}" }.join(', ')}}"
        when "nan"   then "NaN"
        when "inf"   then tagged["sign"].to_i.negative? ? "-Infinity" : "Infinity"
        else tagged["v"].to_s
        end
      end

      private

      # JSON cannot carry these, so they get their own tags rather than being
      # silently coerced to null (spec v0.3 §9).
      def encode_float(value)
        return { "t" => "nan" } if value.nan?
        return { "t" => "inf", "sign" => value.negative? ? -1 : 1 } if value.infinite?

        { "t" => "float", "v" => value.round(10) }
      end

      # A binary string would make JSON.generate raise, which crypto and file code
      # hits constantly.
      #
      # pack("m0") rather than Base64: base64 left Ruby's default gems in 3.4, so
      # `require "base64"` raises on a modern Ruby unless the app happens to bundle
      # it. pack is core and always there - which matters twice over, because the
      # probe generated from this vocabulary is stdlib-only by contract.
      def encode_string(value)
        if value.encoding == Encoding::ASCII_8BIT || !value.valid_encoding?
          return { "t" => "bin", "v" => [value].pack("m0"), "enc" => value.encoding.to_s }
        end

        { "t" => "str", "v" => value }
      end

      # Insertion order preserved, and keys tagged too: a Hash with symbol keys and
      # one with string keys are different arguments.
      def encode_hash(value)
        { "t" => "hash", "v" => value.map { |key, element| [encode(key), encode(element)] } }
      end
    end
  end
end
