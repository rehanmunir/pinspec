# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Pinspec
  module Inputs
    class SampleRunner
      SCRIPT_PATH = "tmp/pinspec/sampler.rb"

      Result = Data.define(:env, :counts, :rows, :stratified, :errors) do
        def total_rows
          counts.values.sum
        end

        def empty?
          total_rows.zero?
        end

        def rows_for(table)
          seen = {}

          (Array(rows[table]) + Array(stratified[table])).each do |row|
            seen[row["id"] || row[:id] || row.hash] = row
          end

          seen.values
        end

        def all_rows
          counts.keys.each_with_object({}) { |table, out| out[table] = rows_for(table) }
        end
      end

      def initialize(app_root:, env: {}, rails_env: "development", timeout: 300)
        @app_root = app_root
        @env = env
        @rails_env = rails_env
        @timeout = timeout
      end

      def fetch(requests)
        write_script!(Sampler.script_for(requests))

        stdout, stderr, status = Open3.capture3(environment, *command, chdir: @app_root)

        unless status.success?
          raise ProbeFailure,
                "the sampler exited #{status.exitstatus} in #{@app_root}.\n" \
                "#{excerpt(stderr)}"
        end

        parse(stdout, stderr)
      end

      private

      def write_script!(source)
        path = File.join(@app_root, SCRIPT_PATH)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        path
      end

      # A boot failure says WHAT went wrong on its first line and where on the rest.
      # Showing only the last N lines shows the bottom of a backtrace - gem_prelude,
      # rubygems.rb - which is identical for every failure and identifies none of them.
      # Diagnosing a real application's failure took three commands and a read of
      # pinspec's own internals because of that.
      def excerpt(text, head: 6, tail: 6)
        lines = text.to_s.lines
        return lines.join if lines.size <= head + tail

        lines.first(head).join +
          "  ... #{lines.size - head - tail} more line(s) ...\n" +
          lines.last(tail).join
      end

      def command
        return ["rails", "runner", SCRIPT_PATH] unless File.file?(File.join(@app_root, "Gemfile"))

        ["bundle", "exec", "rails", "runner", SCRIPT_PATH]
      end

      def environment
        Runner::Runtime.for(@app_root).env
                       .merge("RAILS_ENV" => @rails_env, "DISABLE_SPRING" => "1", "TZ" => "UTC")
                       .merge(@env)
      end

      def parse(stdout, stderr)
        json = stdout.to_s.lines.reverse.find { |line| line.strip.start_with?("{") }

        if json.nil?
          raise ProbeFailure,
                "the sampler produced no rows.\nstdout: #{excerpt(stdout)}\nstderr: #{excerpt(stderr)}"
        end

        parsed = JSON.parse(json)

        Result.new(
          env: parsed["env"], counts: parsed["counts"] || {}, rows: parsed["rows"] || {},
          stratified: parsed["stratified"] || {}, errors: parsed["errors"] || []
        )
      rescue JSON::ParserError => e
        raise ProbeFailure, "the sampler's output was not JSON (#{e.message})"
      end
    end
  end
end
