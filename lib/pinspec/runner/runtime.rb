# frozen_string_literal: true

module Pinspec
  module Runner
    class Runtime
      MANAGERS = %i[rvm rbenv asdf mise chruby].freeze

      Result = Data.define(:env, :ruby_version, :manager, :note) do
        def detected?
          !manager.nil?
        end

        def same_ruby?
          manager.nil? && note.nil?
        end
      end

      BUNDLER_VARS = %w[
        BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLE_APP_CONFIG
        BUNDLER_VERSION BUNDLER_SETUP RUBYOPT RUBYLIB
      ].freeze

      def self.for(app_root, home: Dir.home, current: RUBY_VERSION)
        new(app_root, home: home, current: current).resolve
      end

      def initialize(app_root, home: Dir.home, current: RUBY_VERSION)
        @app_root = app_root
        @home = home
        @current = current
      end

      def resolve
        wanted = declared_version
        return Result.new(env: scrub, ruby_version: @current, manager: nil, note: nil) if wanted.nil?
        return Result.new(env: scrub, ruby_version: @current, manager: nil, note: nil) if satisfied_by_current?(wanted)

        found = MANAGERS.filter_map { |manager| send(:"#{manager}_env", wanted)&.then { |e| [manager, e] } }.first

        if found.nil?
          return Result.new(
            env: scrub, ruby_version: wanted, manager: nil,
            note: "#{@app_root} declares Ruby #{wanted} and this is #{@current}, but no " \
                  "installation of #{wanted} was found under rvm, rbenv, asdf, mise or " \
                  "chruby. Pass the app's runtime explicitly:\n" \
                  "  --app-env PATH=/path/to/ruby-#{wanted}/bin:$PATH"
          )
        end

        manager, env = found
        Result.new(env: scrub.merge(env), ruby_version: wanted, manager: manager, note: nil)
      end

      def declared_version
        from_file(".ruby-version") || from_tool_versions
      end

      private

      # Only bundler's variables are removed. GEM_HOME and GEM_PATH are left alone:
      # dropping them is what forced every invocation to hand the app's gemset back
      # by hand, and they are only wrong when the app runs on a different Ruby - in
      # which case the detected runtime overwrites them anyway.
      def scrub
        BUNDLER_VARS.to_h { |name| [name, nil] }
      end

      def from_file(name)
        path = File.join(@app_root, name)
        return nil unless File.file?(path)

        Analyzer::Source.read(path).strip[/\d+\.\d+(\.\d+)?/]
      end

      def from_tool_versions
        path = File.join(@app_root, ".tool-versions")
        return nil unless File.file?(path)

        Analyzer::Source.read(path)[/^\s*ruby\s+(\S+)/, 1]&.[](/\d+\.\d+(\.\d+)?/)
      end

      # A patch-level difference is not worth relocating the runtime for: 3.3.0 and
      # 3.3.6 run the same code. A minor difference is.
      def satisfied_by_current?(wanted)
        @current == wanted || series(@current) == series(wanted)
      end

      def series(version)
        version.to_s.split(".").first(2).join(".")
      end

      def rvm_env(wanted)
        root = File.join(@home, ".rvm")
        ruby = File.join(root, "rubies", "ruby-#{wanted}", "bin")
        return nil unless File.directory?(ruby)

        gems = File.join(root, "gems", "ruby-#{wanted}")
        env = { "PATH" => prepend(ruby) }
        if File.directory?(gems)
          env["GEM_HOME"] = gems
          env["GEM_PATH"] = "#{gems}:#{gems}@global"
        end
        env
      end

      def rbenv_env(wanted)
        bin = File.join(@home, ".rbenv", "versions", wanted, "bin")
        File.directory?(bin) ? { "PATH" => prepend(bin), "RBENV_VERSION" => wanted } : nil
      end

      def asdf_env(wanted)
        bin = File.join(@home, ".asdf", "installs", "ruby", wanted, "bin")
        File.directory?(bin) ? { "PATH" => prepend(bin) } : nil
      end

      def mise_env(wanted)
        bin = File.join(@home, ".local", "share", "mise", "installs", "ruby", wanted, "bin")
        File.directory?(bin) ? { "PATH" => prepend(bin) } : nil
      end

      def chruby_env(wanted)
        bin = File.join(@home, ".rubies", "ruby-#{wanted}", "bin")
        File.directory?(bin) ? { "PATH" => prepend(bin) } : nil
      end

      def prepend(bin)
        [bin, ENV.fetch("PATH", "")].reject(&:empty?).join(File::PATH_SEPARATOR)
      end
    end
  end
end
