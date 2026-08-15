# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Pinspec::Runner::Runtime do
  let(:app) { Dir.mktmpdir }
  let(:home) { Dir.mktmpdir }

  def declare(version, file: ".ruby-version")
    body = file == ".tool-versions" ? "nodejs 20.11.0\nruby #{version}\n" : "#{version}\n"
    File.write(File.join(app, file), body)
  end

  def install(manager, version, gemset: false)
    path = case manager
           when :rvm then File.join(home, ".rvm/rubies/ruby-#{version}/bin")
           when :rbenv then File.join(home, ".rbenv/versions/#{version}/bin")
           when :asdf then File.join(home, ".asdf/installs/ruby/#{version}/bin")
           when :mise then File.join(home, ".local/share/mise/installs/ruby/#{version}/bin")
           when :chruby then File.join(home, ".rubies/ruby-#{version}/bin")
           end
    FileUtils.mkdir_p(path)
    FileUtils.mkdir_p(File.join(home, ".rvm/gems/ruby-#{version}")) if gemset
    path
  end

  def resolve(current: "3.4.6")
    described_class.for(app, home: home, current: current)
  end

  describe "what it scrubs" do
    it "removes bundler's variables, which are the ones that leak" do
      env = resolve.env

      %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLER_VERSION RUBYOPT RUBYLIB].each do |name|
        expect(env).to have_key(name)
        expect(env[name]).to be_nil
      end
    end

    # Dropping these is what made every invocation against a real app hand the
    # gemset back by hand. They are only wrong when the app runs on a different
    # Ruby, and then the detected runtime overwrites them anyway.
    it "leaves GEM_HOME and GEM_PATH alone" do
      expect(resolve.env).not_to have_key("GEM_HOME")
      expect(resolve.env).not_to have_key("GEM_PATH")
    end
  end

  describe "when the app runs on the Ruby already in hand" do
    it "does nothing when no version is declared" do
      expect(resolve).to be_same_ruby
      expect(resolve.env.values.compact).to be_empty
    end

    it "does nothing when the declared version matches" do
      declare("3.4.6")

      expect(resolve).to be_same_ruby
    end

    # 3.4.2 and 3.4.6 run the same code; relocating the runtime for a patch
    # difference would fail for no reason on a machine that has only one of them.
    it "treats a patch-level difference as the same runtime" do
      declare("3.4.2")

      expect(resolve).to be_same_ruby
    end

    it "does not treat a minor difference as the same runtime" do
      declare("3.3.0")
      install(:rbenv, "3.3.0")

      expect(resolve).not_to be_same_ruby
      expect(resolve.ruby_version).to eq("3.3.0")
    end
  end

  describe "finding the Ruby the app asked for" do
    it "finds an rvm ruby, with its gemset" do
      bin = install(:rvm, "3.3.0", gemset: true)
      declare("3.3.0")

      result = resolve

      expect(result.manager).to eq(:rvm)
      expect(result.env["PATH"]).to start_with(bin)
      expect(result.env["GEM_HOME"]).to end_with("gems/ruby-3.3.0")
      expect(result.env["GEM_PATH"]).to include("@global")
    end

    it "finds an rvm ruby that has no gemset directory" do
      install(:rvm, "3.3.0")
      declare("3.3.0")

      expect(resolve.env).not_to have_key("GEM_HOME")
      expect(resolve.manager).to eq(:rvm)
    end

    %i[rbenv asdf mise chruby].each do |manager|
      it "finds a #{manager} ruby" do
        bin = install(manager, "3.2.2")
        declare("3.2.2")

        result = resolve

        expect(result.manager).to eq(manager)
        expect(result.env["PATH"]).to start_with(bin)
      end
    end

    it "sets RBENV_VERSION so a shim resolves the right ruby" do
      install(:rbenv, "3.2.2")
      declare("3.2.2")

      expect(resolve.env["RBENV_VERSION"]).to eq("3.2.2")
    end

    it "reads .tool-versions when there is no .ruby-version" do
      install(:asdf, "3.2.2")
      declare("3.2.2", file: ".tool-versions")

      expect(resolve.manager).to eq(:asdf)
      expect(resolve.ruby_version).to eq("3.2.2")
    end

    it "prefers .ruby-version over .tool-versions" do
      declare("3.3.0")
      declare("3.2.2", file: ".tool-versions")

      expect(described_class.new(app, home: home, current: "3.4.6").declared_version).to eq("3.3.0")
    end

    it "keeps the current PATH behind the one it prepends" do
      install(:rbenv, "3.2.2")
      declare("3.2.2")

      expect(resolve.env["PATH"]).to include(ENV.fetch("PATH"))
    end
  end

  # The failure mode that matters: not being able to find it is fine, but the
  # message has to say what to paste, because the alternative is a Rails boot error
  # that names the application rather than the missing runtime.
  describe "when it cannot find the Ruby" do
    before { declare("2.9.9") }

    it "does not guess" do
      expect(resolve.manager).to be_nil
    end

    it "says which version, which is running, and what to pass" do
      note = resolve.note

      expect(note).to include("declares Ruby 2.9.9")
      expect(note).to include("this is 3.4.6")
      expect(note).to include("rvm, rbenv, asdf, mise or")
      expect(note).to include("--app-env PATH=")
    end

    it "still scrubs bundler, so the failure is about the Ruby and nothing else" do
      expect(resolve.env["BUNDLE_GEMFILE"]).to be_nil
    end
  end
end
