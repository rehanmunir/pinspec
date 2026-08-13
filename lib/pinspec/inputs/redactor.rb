# frozen_string_literal: true

require "digest"

module Pinspec
  module Inputs
    class Redactor
      BUILT_IN = %w[
        email phone phone_number mobile
        ssn social_security_number
        dob date_of_birth birthdate
        first_name last_name full_name middle_name maiden_name
        address address1 address2 address_line1 address_line2 street city postcode zip zipcode
        ip_address remote_ip
        token api_key access_token refresh_token secret password_digest encrypted_password
      ].freeze

      def initialize(attributes: [], enabled: true)
        @extra   = Array(attributes).map(&:to_s)
        @enabled = enabled
      end

      def enabled?
        @enabled
      end

      PERSON_TABLES = %w[
        customers users people contacts employees members clients patients
        subscribers accounts admins authors owners guests students staff
      ].freeze

      PERSON_COLUMNS = %w[name display_name nickname username handle].freeze

      def redacts?(column_name, table: nil)
        return false unless @enabled

        name = column_name.to_s
        return true if BUILT_IN.include?(name) || @extra.include?(name)

        PERSON_COLUMNS.include?(name) && PERSON_TABLES.include?(table.to_s)
      end

      def redact(attrs, ordinal:, table: nil)
        redacted = []

        rewritten = attrs.each_with_object({}) do |(column, value), out|
          if redacts?(column, table: table) && value.is_a?(String) && !value.empty?
            out[column] = rewrite(column.to_s, value, ordinal)
            redacted << column.to_s
          else
            out[column] = value
          end
        end

        [rewritten, redacted]
      end

      def reads_in(source, columns)
        return [] unless @enabled

        Array(columns).uniq.filter_map do |column|
          line = read_line(source, column.to_s)
          next unless line

          { attribute: column.to_s, line: line }
        end
      end

      private

      def read_line(source, column)
        pattern = /(?:\.#{Regexp.escape(column)}\b|:#{Regexp.escape(column)}\b|["']#{Regexp.escape(column)}["'])/

        source.to_s.lines.each_with_index do |text, index|
          return index + 1 if text.match?(pattern)
        end

        nil
      end

      def rewrite(column, value, ordinal)
        case column
        when /email/                       then rewrite_email(value, ordinal)
        when /phone|mobile/                then rewrite_digits(value, ordinal)
        when /ssn|social_security/         then rewrite_digits(value, ordinal)
        when /dob|birth/                   then rewrite_date(value)
        when /token|key|secret|password/   then rewrite_hex(value, ordinal)
        when /ip_address|remote_ip/        then rewrite_ip(value, ordinal)
        else rewrite_filler(value, ordinal)
        end
      end

      def rewrite_email(value, ordinal)
        local, _, domain = value.rpartition("@")
        return rewrite_filler(value, ordinal) if domain.empty? || local.empty?

        "#{same_length_token(local, ordinal)}@#{domain}"
      end

      def rewrite_digits(value, ordinal)
        counter = ordinal.abs
        digits  = format("%0#{value.count('0-9')}d", counter)
        index   = -1

        value.gsub(/\d/) do
          index += 1
          digits[index] || "0"
        end
      end

      def rewrite_date(value)
        value.match?(/\A\d{4}-\d{2}-\d{2}/) ? "1970-01-01#{value[10..]}" : value
      end

      def rewrite_hex(value, ordinal)
        digest = Digest::SHA256.hexdigest("pinspec:#{ordinal}")
        (digest * ((value.length / digest.length) + 1))[0, value.length]
      end

      def rewrite_ip(value, ordinal)
        return rewrite_digits(value, ordinal) if value.include?(":")

        "192.0.2.#{(ordinal.abs % 254) + 1}"
      end

      def rewrite_filler(value, ordinal)
        same_length_token(value, ordinal)
      end

      def same_length_token(value, ordinal)
        seed = "p#{ordinal}"
        return seed[0, value.length] if seed.length >= value.length

        seed + ("x" * (value.length - seed.length))
      end
    end
  end
end
