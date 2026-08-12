# frozen_string_literal: true

require "prism"

# pinspec's own verification matrix runs specs under `LANG=C LC_ALL=C`
# (spec v0.3 §7 M-13, the :hostile config). A CLI that writes non-ASCII to a
# stream under that locale produces mojibake in exactly the logs someone will be
# reading when something has already gone wrong.
#
# Comments are exempt: Ruby reads source as UTF-8 regardless of locale, and a
# comment never reaches a stream. String literals are not exempt, because any of
# them can end up in an error message.
#
# This guard is Prism reading pinspec's own source, which is the same thing
# M-01 does to a target.
RSpec.describe "user-facing output" do
  ROOT_DIR = File.expand_path("..", __dir__)

  def string_literals(path)
    source  = File.read(path, encoding: "UTF-8")
    found   = []
    collect = lambda do |node|
      found << node if node.is_a?(Prism::StringNode)
      node.compact_child_nodes.each { |child| collect.call(child) }
    end

    collect.call(Prism.parse(source).value)
    found
  end

  shipped = Dir[File.join(ROOT_DIR, "lib/**/*.rb"), File.join(ROOT_DIR, "exe/*")].sort

  it "has files to check" do
    expect(shipped).not_to be_empty
  end

  shipped.each do |path|
    relative = path.delete_prefix("#{ROOT_DIR}/")

    it "keeps every string literal in #{relative} ASCII-only" do
      offenders = string_literals(path).reject { |node| node.location.slice.ascii_only? }

      messages = offenders.map do |node|
        "line #{node.location.start_line}: #{node.location.slice}"
      end

      expect(offenders).to be_empty,
                           "non-ASCII string literals would garble under LANG=C:\n  " \
                           "#{messages.join("\n  ")}"
    end
  end
end
