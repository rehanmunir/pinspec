# frozen_string_literal: true

module PinspecSerializer
  MAX_DEPTH = 4
  DEFAULT_MAX_COLLECTION = 50

  VOLATILE = %w[created_at updated_at].freeze
  DB_FUNCTION_DEFAULT = /\A(?:gen_random_uuid|now|uuid_generate_v4|CURRENT_|nextval)/i.freeze

  class << self
    def normalize(value, refs:, fk_map:, max_collection: DEFAULT_MAX_COLLECTION)
      encode(value, refs: refs, fk_map: fk_map, max_collection: max_collection)
    end

    def encode(value, refs: {}, fk_map: {}, max_collection: DEFAULT_MAX_COLLECTION)
      @refs = refs || {}
      @fk_map = fk_map || {}
      @max_collection = max_collection
      @id_index = build_id_index(@refs)

      visit(value, 0, [])
    end

    RETURNED_REF = "__returned__"

    def build_id_index(refs)
      index = {}

      refs.each do |key, ref|
        id = key.to_s.split(":").last
        next unless id =~ /\A\d+\z/

        numeric = id.to_i

        if !index.key?(numeric)
          index[numeric] = ref
        elsif ref == RETURNED_REF || index[numeric] == RETURNED_REF
          index[numeric] = RETURNED_REF
        else
          index[numeric] = :ambiguous
        end
      end

      index
    end

    private

    def visit(value, depth, seen)
      return { "t" => "truncated" } if depth > MAX_DEPTH

      case value
      when nil then { "t" => "nil" }
      when true then { "t" => "bool", "v" => true }
      when false then { "t" => "bool", "v" => false }
      when Integer then encode_integer(value)
      when Float then encode_float(value)
      when Symbol then { "t" => "sym", "v" => value.to_s }
      when String then encode_string(value)
      when Array then encode_array(value, depth, seen)
      when Hash then encode_hash(value, depth, seen)
      else encode_object(value, depth, seen)
      end
    end

    def encode_integer(value)
      ref = @id_index[value]
      return { "t" => "ref", "v" => ref } if ref && ref != :ambiguous

      { "t" => "int", "v" => value }
    end

    def encode_float(value)
      return { "t" => "nan" } if value.nan?
      return { "t" => "inf", "sign" => (value < 0 ? -1 : 1) } if value.infinite?

      { "t" => "float", "v" => value.round(10) }
    end

    GLOBAL_ID = %r{\Agid://[^/]+/([A-Za-z0-9:_]+)/(.+)\z}.freeze

    def encode_string(value)
      if value.encoding == Encoding::ASCII_8BIT || !value.valid_encoding?
        return { "t" => "bin", "v" => [value].pack("m0"), "enc" => value.encoding.to_s }
      end

      match = GLOBAL_ID.match(value)
      return encode_global_id(match[1], match[2]) if match

      { "t" => "str", "v" => value }
    end

    def encode_global_id(model, id)
      out = { "t" => "gid", "model" => model }

      ref = id =~ /\A\d+\z/ ? @id_index[id.to_i] : nil
      if ref && ref != :ambiguous
        out["ref"] = ref
      else
        out["id"] = "seq"
      end

      out
    end

    def encode_array(value, depth, seen)
      if value.length > @max_collection
        return {
          "t" => "relation",
          "total" => value.length,
          "first" => value.first(@max_collection).map { |element| visit(element, depth + 1, seen) }
        }
      end

      { "t" => "array", "v" => value.map { |element| visit(element, depth + 1, seen) } }
    end

    def encode_hash(value, depth, seen)
      pairs = value.map do |key, element|
        [visit(key, depth + 1, seen), visit(element, depth + 1, seen)]
      end

      { "t" => "hash", "v" => pairs }
    end

    def encode_object(value, depth, seen)
      return { "t" => "cycle", "class" => value.class.name.to_s } if seen.include?(value.object_id)

      nested = seen + [value.object_id]

      return encode_record(value, depth, nested) if active_record?(value)
      return encode_relation(value, depth, nested) if relation?(value)
      return { "t" => "decimal", "v" => value.to_s("F") } if big_decimal?(value)
      return encode_time(value) if value.is_a?(Time)
      return encode_time(value.to_time) if defined?(DateTime) && value.is_a?(DateTime)
      return { "t" => "date", "v" => value.strftime("%Y-%m-%d") } if defined?(Date) && value.is_a?(Date)
      return { "t" => "exception", "class" => value.class.name.to_s, "message" => value.message.to_s } if value.is_a?(Exception)
      return { "t" => "unpinnable", "class" => value.class.name.to_s } if unpinnable?(value)

      encode_plain_object(value, depth, nested)
    end

    def encode_time(value)
      { "t" => "time", "v" => value.getutc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ") }
    end

    def encode_record(record, depth, seen)
      table = record.class.table_name
      out = {
        "t" => "record",
        "class" => record.class.name.to_s
      }

      ref = @refs[identity_key(table, record)]
      out["ref"] = ref if ref

      attributes = {}
      record.attributes.each do |name, value|
        next if name == record.class.primary_key
        next if VOLATILE.include?(name)
        next if db_function_default?(record.class, name)

        attributes[name] = encode_attribute(table, name, value, depth, seen)
      end

      out["attributes"] = attributes
      out
    end

    def encode_attribute(table, name, value, depth, seen)
      target = @fk_map["#{table}.#{name}"]

      if target && !value.nil?
        ref = @refs["#{target}:#{value}"]
        return { "t" => "ref", "v" => ref } if ref

        return { "t" => "seq" }
      end

      return { "t" => "seq" } if unresolvable_id?(name, value)

      visit(value, depth + 1, seen)
    end

    def unresolvable_id?(name, value)
      return false if value.nil?
      return true if name.to_s =~ /_id\z/ && value.is_a?(Integer)
      return true if name.to_s =~ /_ids\z/ && value.is_a?(Array)

      false
    end

    def identity_key(table, record)
      "#{table}:#{record.id}"
    end

    def db_function_default?(klass, name)
      column = klass.columns_hash[name]
      return false if column.nil? || column.default_function.nil?

      column.default_function.to_s =~ DB_FUNCTION_DEFAULT ? true : false
    end

    def encode_relation(relation, depth, seen)
      total = relation.size
      rows = relation.first(@max_collection)

      {
        "t" => "relation",
        "total" => total,
        "first" => rows.map { |row| visit(row, depth + 1, seen) }
      }
    end

    def encode_plain_object(value, depth, seen)
      state = {}

      value.instance_variables.each do |name|
        state[name.to_s] = visit(value.instance_variable_get(name), depth + 1, seen)
      end

      { "t" => "object", "class" => value.class.name.to_s, "ivars" => state }
    end

    def active_record?(value)
      defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base)
    end

    def relation?(value)
      defined?(ActiveRecord::Relation) && value.is_a?(ActiveRecord::Relation)
    end

    def big_decimal?(value)
      defined?(BigDecimal) && value.is_a?(BigDecimal)
    end

    def unpinnable?(value)
      value.is_a?(Proc) || value.is_a?(IO) ||
        (defined?(Method) && value.is_a?(Method)) ||
        (defined?(Thread) && value.is_a?(Thread))
    end
  end
end
