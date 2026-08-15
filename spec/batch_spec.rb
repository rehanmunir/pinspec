# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Pinspec::Batch do
  describe ".targets_in" do
    let(:root) { Dir.mktmpdir }

    def touch(*relative)
      relative.each do |path|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        FileUtils.touch(full)
      end
    end

    it "returns a single file unchanged" do
      touch("app/services/one.rb")
      file = File.join(root, "app/services/one.rb")

      expect(described_class.targets_in(file)).to eq([file])
    end

    it "finds ruby files recursively, in a stable order" do
      touch("services/b.rb", "services/a.rb", "services/nested/c.rb")

      expect(described_class.targets_in(File.join(root, "services")).map { |f| File.basename(f) })
        .to eq(%w[a.rb b.rb c.rb])
    end

    it "skips concerns, specs and tests" do
      touch("services/real.rb", "services/concerns/mixin.rb",
            "services/thing_spec.rb", "services/spec/helper.rb", "services/test/helper.rb")

      expect(described_class.targets_in(File.join(root, "services")).map { |f| File.basename(f) })
        .to eq(["real.rb"])
    end

    # The patterns are matched against the path RELATIVE to the directory. Matching
    # the absolute path meant an application living anywhere under a directory named
    # `spec` had every one of its files skipped - which is exactly what happened to
    # pinspec's own fixture app.
    it "does not skip an app that merely lives under a path containing spec" do
      nested = File.join(root, "spec", "fixtures", "myapp", "app", "services")
      FileUtils.mkdir_p(nested)
      FileUtils.touch(File.join(nested, "real.rb"))

      expect(described_class.targets_in(nested).map { |f| File.basename(f) }).to eq(["real.rb"])
    end

    it "returns nothing for a directory with no ruby in it" do
      touch("services/readme.md")

      expect(described_class.targets_in(File.join(root, "services"))).to be_empty
    end
  end

  describe "running over several files" do
    def outcome(file, status)
      Pinspec::Batch::Outcome.new(file: file, target: "X#call", status: status,
                                  detail: "", pinned: 1, spec_path: "spec/x.rb")
    end

    # A refusal is information, not a stop. One target that takes a block must not
    # end a run over a directory of forty.
    it "keeps going when a target is refused, and records why" do
      seen = []
      report = described_class.new(%w[a.rb b.rb c.rb]) do |file|
        seen << file
        raise Pinspec::BlockRequired, "takes a block" if file == "b.rb"

        outcome(file, :pinned)
      end.run

      expect(seen).to eq(%w[a.rb b.rb c.rb])
      expect(report.pinned.map(&:file)).to eq(%w[a.rb c.rb])
      expect(report.refused.map(&:file)).to eq(["b.rb"])
      expect(report.refused.first.detail).to eq("BlockRequired")
    end

    it "names the reason on a refusal that carries one" do
      report = described_class.new(%w[a.rb]) do
        raise Pinspec::UnresolvableSetup.new(:unresolvable_parameter, "no factory")
      end.run

      expect(report.refused.first.detail).to eq("UnresolvableSetup(unresolvable_parameter)")
    end

    # A verify failure is a different thing from a refusal: the pin exists and is not
    # trustworthy, which is worth separating in the summary.
    it "separates a failure from a refusal" do
      report = described_class.new(%w[a.rb b.rb]) do |file|
        raise Pinspec::VerifyFailed, "did not run green in hostile" if file == "a.rb"

        outcome(file, :pinned)
      end.run

      expect(report.failed.map(&:file)).to eq(["a.rb"])
      expect(report.refused).to be_empty
      expect(report.failed.first.detail).to include("did not run green")
    end

    it "reports whether anything was pinned at all" do
      nothing = described_class.new(%w[a.rb]) { raise Pinspec::BlockRequired, "x" }.run
      something = described_class.new(%w[a.rb]) { |f| outcome(f, :pinned) }.run

      expect(nothing).not_to be_anything_pinned
      expect(something).to be_anything_pinned
    end

    # An error pinspec does not recognise is a bug in pinspec, and swallowing it into
    # a summary row would hide it.
    it "does not swallow an unexpected error" do
      expect { described_class.new(%w[a.rb]) { raise NoMethodError, "boom" }.run }
        .to raise_error(NoMethodError)
    end
  end
end
