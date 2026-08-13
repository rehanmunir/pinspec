# frozen_string_literal: true

require "digest"

module Pinspec
  module Inputs
    # Rewrites personal data out of sampled rows before it reaches a plan, a
    # snapshot, or a committed spec file.
    #
    # Domain- AND length-preserving, which is the whole difference between this and
    # a naive redactor. v0.2 rewrote an email to `user1@example.test`, changing both
    # the domain and the length - so a target that routes on the domain, or
    # validates or truncates on length, observes different behaviour, the probe
    # captures it, the verifier goes green, and the committed snapshot freezes
    # behaviour that never happens. A redactor that changes behaviour is worse than
    # no redactor, because it looks correct.
    #
    # Every rewrite is deterministic and index-based: the same row always redacts to
    # the same value, so a plan stays content-addressable.
    class Redactor
      # Spec v0.3 §7 M-06's built-in list. `name` is deliberately absent: it is far
      # too common as a non-personal column (a product name, a status name) and
      # redacting it would rewrite half of every schema.
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

      # Tables whose rows are people. `name` on one of these is personal data; on
      # a products or statuses table it is not, which is why a flat list cannot
      # answer it and the table has to be part of the question.
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

      # Returns [rewritten_attrs, redacted_column_names]. When redaction is off,
      # redacts? answers false for everything and the row passes through unchanged.
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

      # Which redacted attributes the target actually reads. A rewritten value the
      # target inspects is a pin of behaviour that never happens, so this is a
      # warning the emitted spec carries rather than a report footnote (row 34).
      #
      # Honest limit, stated wherever this is surfaced: a single-file scan cannot
      # see transitive callees, so no hit is not proof of no read.
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

      # The domain survives, because a target that splits on "@" or checks an
      # allowlist is checking the domain. The local part keeps its length.
      def rewrite_email(value, ordinal)
        local, _, domain = value.rpartition("@")
        return rewrite_filler(value, ordinal) if domain.empty? || local.empty?

        "#{same_length_token(local, ordinal)}@#{domain}"
      end

      # Every non-digit stays exactly where it was, so "+1 (555) 010-1234" keeps
      # its shape and anything parsing it still parses it.
      def rewrite_digits(value, ordinal)
        counter = ordinal.abs
        digits  = format("%0#{value.count('0-9')}d", counter)
        index   = -1

        value.gsub(/\d/) do
          index += 1
          digits[index] || "0"
        end
      end

      # A date cannot be length-preserved into meaninglessness without breaking age
      # arithmetic either way, so it moves to one fixed date and the change is
      # reported like any other.
      def rewrite_date(value)
        value.match?(/\A\d{4}-\d{2}-\d{2}/) ? "1970-01-01#{value[10..]}" : value
      end

      def rewrite_hex(value, ordinal)
        digest = Digest::SHA256.hexdigest("pinspec:#{ordinal}")
        (digest * ((value.length / digest.length) + 1))[0, value.length]
      end

      def rewrite_ip(value, ordinal)
        return rewrite_digits(value, ordinal) if value.include?(":") # IPv6: keep shape

        "192.0.2.#{(ordinal.abs % 254) + 1}"
      end

      # Same length, deterministic, and obviously synthetic when read by a human.
      def rewrite_filler(value, ordinal)
        same_length_token(value, ordinal)
      end

      # The ordinal comes first so it survives truncation. "Person#{ordinal}"
      # truncated to six characters is "Person" for every row, which would collide
      # two different people onto one value - and straight into a unique index.
      def same_length_token(value, ordinal)
        seed = "p#{ordinal}"
        return seed[0, value.length] if seed.length >= value.length

        seed + ("x" * (value.length - seed.length))
      end
    end
  end
end
