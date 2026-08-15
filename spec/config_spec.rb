# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Pinspec::Config do
  let(:app) { Dir.mktmpdir }

  def write(body)
    File.write(File.join(app, described_class::FILENAME), body)
  end

  describe "when there is no file" do
    subject(:config) { described_class.load(app) }

    it "loads without complaint" do
      expect(config).not_to be_exist
      expect(config.env).to eq({})
    end

    it "returns the default for every setting" do
      expect(config.value("cases", 12, 12)).to eq(12)
      expect(config.value("boots", 2, 2)).to eq(2)
    end
  end

  describe "precedence" do
    before { write("cases: 5\nboots: 3\n") }

    subject(:config) { described_class.load(app) }

    it "uses the file when the flag was left at its default" do
      expect(config.value("cases", 12, 12)).to eq(5)
      expect(config.value("boots", 2, 2)).to eq(3)
    end

    # Thor cannot distinguish a flag that was typed from one that defaulted, so the
    # caller passes the default separately - anything else wins.
    it "uses the flag when one was typed" do
      expect(config.value("cases", 40, 12)).to eq(40)
    end

    it "falls back to the default for a key the file does not set" do
      expect(config.value("verify-level", "full", "full")).to eq("full")
    end
  end

  describe "env" do
    it "reads a mapping of strings" do
      write("env:\n  DATABASE_USERNAME: myapp\n  PGPORT: 5433\n")

      expect(described_class.load(app).env).to eq("DATABASE_USERNAME" => "myapp", "PGPORT" => "5433")
    end

    it "refuses an env that is not a mapping" do
      write("env: DATABASE_USERNAME=myapp\n")

      expect { described_class.load(app).env }.to raise_error(Pinspec::ConfigInvalid, /must be a mapping/)
    end
  end

  # A typo in a config file is otherwise silent, and the user concludes the setting
  # does not work.
  describe "refusing what it cannot honour" do
    it "names an unknown key and lists the ones it knows" do
      write("case: 5\n")

      expect { described_class.load(app) }
        .to raise_error(Pinspec::ConfigInvalid) { |error|
          expect(error.message).to include('unknown key "case"')
          expect(error.message).to include("cases")
        }
    end

    it "pluralises when there is more than one" do
      write("case: 5\nboot: 2\n")

      expect { described_class.load(app) }.to raise_error(/unknown keys/)
    end

    it "reports invalid YAML as a config problem, not a crash" do
      write("cases: [1,\n")

      expect { described_class.load(app) }.to raise_error(Pinspec::ConfigInvalid, /not valid YAML/)
    end

    it "refuses a document that is not a mapping" do
      write("- cases\n")

      expect { described_class.load(app) }.to raise_error(Pinspec::ConfigInvalid, /must contain a mapping/)
    end

    it "has its own exit code" do
      expect(Pinspec::ConfigInvalid.exit_code).to eq(13)
    end
  end

  describe "the document init writes" do
    subject(:document) { described_class.new(app, { "cases" => 12, "boots" => 2 }, nil).to_yaml_document }

    it "round-trips" do
      write(document)

      expect(described_class.load(app).value("cases", 12, 12)).to eq(12)
    end

    # Writing the resolved PATH into a committed file bakes in one machine's layout
    # and goes stale the moment the app changes Ruby.
    it "records no environment, because the runtime is detected on each run" do
      expect(document).not_to include("PATH")
      expect(document).not_to include(Dir.home)
      expect(document).to include("detected on each run")
    end

    it "shows what env is actually for" do
      expect(document).to include("DATABASE_USERNAME")
    end
  end
end
