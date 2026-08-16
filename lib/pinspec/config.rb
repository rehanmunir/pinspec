# frozen_string_literal: true

require "yaml"

module Pinspec
  class Config
    FILENAME = ".pinspec.yml"

    KEYS = %w[cases boots sample redact compare-sql verify-level test-command env].freeze

    # Keys that used to be valid. A config written for an older pinspec is ignored
    # with a note rather than failing the run - an upgrade should not stop a build.
    RETIRED_KEYS = %w[snapshot].freeze

    EMPTY = { "env" => {} }.freeze

    def self.load(app_root)
      path = File.join(app_root.to_s, FILENAME)
      return new(app_root, EMPTY, nil) unless File.file?(path)

      parsed = YAML.safe_load(Analyzer::Source.read(path), permitted_classes: [], aliases: false) || {}
      raise ConfigInvalid, "#{path} must contain a mapping, got #{parsed.class}" unless parsed.is_a?(Hash)

      retired = parsed.keys.map(&:to_s) & RETIRED_KEYS
      unless retired.empty?
        warn "pinspec: #{path} sets #{retired.map(&:inspect).join(', ')}, which " \
             "#{retired.size == 1 ? 'was' : 'were'} removed. Ignoring #{retired.size == 1 ? 'it' : 'them'}; " \
             "delete the line to silence this."
      end

      unknown = parsed.keys.map(&:to_s) - KEYS - RETIRED_KEYS
      unless unknown.empty?
        raise ConfigInvalid,
              "#{path} has unknown #{unknown.size == 1 ? 'key' : 'keys'} " \
              "#{unknown.map(&:inspect).join(', ')}. Known keys: #{KEYS.join(', ')}."
      end

      new(app_root, parsed, path)
    rescue Psych::SyntaxError => e
      raise ConfigInvalid, "#{path} is not valid YAML: #{e.message}"
    end

    attr_reader :path

    def initialize(app_root, data, path)
      @app_root = app_root
      @data = data || {}
      @path = path
    end

    def exist?
      !@path.nil?
    end

    def env
      raw = @data["env"] || {}
      raise ConfigInvalid, "#{@path}: `env` must be a mapping of KEY: VALUE" unless raw.is_a?(Hash)

      raw.transform_keys(&:to_s).transform_values(&:to_s)
    end

    def [](key)
      @data[key.to_s]
    end

    # CLI flag beats file beats default. Thor cannot tell a flag that was typed from
    # one that defaulted, so the caller passes the default separately and an option
    # equal to it is treated as untyped.
    def value(key, given, default)
      return given unless given == default || given.nil?

      fetched = @data[key.to_s]
      fetched.nil? ? default : fetched
    end

    def to_yaml_document
      <<~YAML
        # pinspec settings. Every key here is a CLI flag you would otherwise repeat;
        # a flag on the command line still wins.
        #
        # The app's Ruby is detected on each run from .ruby-version or .tool-versions,
        # so it is deliberately not recorded here. Use `env` only for what pinspec
        # cannot work out for itself:
        #
        #   env:
        #     DATABASE_USERNAME: myapp
        #
        #{YAML.dump(@data).sub(/\A---\n/, "").chomp}
      YAML
    end
  end
end
