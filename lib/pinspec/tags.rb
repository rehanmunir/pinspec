# frozen_string_literal: true

require "date"

module Pinspec
  module Tags
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

      def ref(name)
        { "t" => "ref", "v" => name.to_s }
      end

      def decimal(value)
        { "t" => "decimal", "v" => value.to_s }
      end

      def tagged?(value)
        value.is_a?(Hash) && value.key?("t")
      end

      def type_of(value)
        tagged?(value) ? value["t"] : nil
      end

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

      def encode_float(value)
        return { "t" => "nan" } if value.nan?
        return { "t" => "inf", "sign" => value.negative? ? -1 : 1 } if value.infinite?

        { "t" => "float", "v" => value.round(10) }
      end

      def encode_string(value)
        if value.encoding == Encoding::ASCII_8BIT || !value.valid_encoding?
          return { "t" => "bin", "v" => [value].pack("m0"), "enc" => value.encoding.to_s }
        end

        { "t" => "str", "v" => value }
      end

      def encode_hash(value)
        { "t" => "hash", "v" => value.map { |key, element| [encode(key), encode(element)] } }
      end
    end
  end
end
