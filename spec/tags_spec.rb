# frozen_string_literal: true

require "json"

# The serializer-v3 tag vocabulary (spec v0.3 §9). This is one half of §4c's
# encoding axis - M-07's probe encoder and M-09's generated spec helper are built
# from the same vocabulary - so it is a contract, not an implementation detail.
RSpec.describe Pinspec::Tags do
  def round_trip(value)
    described_class.decode(described_class.encode(value))
  end

  describe "everything is tagged" do
    # A bare 5 in cases.json would be ambiguous between an Integer and a decimal
    # that happened to be whole, and the probe would have to guess.
    it "tags values JSON could carry natively" do
      expect(described_class.encode(5)).to eq("t" => "int", "v" => 5)
      expect(described_class.encode("hi")).to eq("t" => "str", "v" => "hi")
      expect(described_class.encode(true)).to eq("t" => "bool", "v" => true)
      expect(described_class.encode(nil)).to eq("t" => "nil")
    end

    it "distinguishes a Symbol from a String" do
      expect(described_class.encode(:draft)).to eq("t" => "sym", "v" => "draft")
      expect(described_class.encode("draft")).to eq("t" => "str", "v" => "draft")
      expect(round_trip(:draft)).to eq(:draft)
    end
  end

  describe "values JSON cannot carry" do
    it "tags NaN rather than letting it become null" do
      expect(described_class.encode(Float::NAN)).to eq("t" => "nan")
      expect(round_trip(Float::NAN)).to be_nan
    end

    it "tags each infinity with its sign" do
      expect(described_class.encode(Float::INFINITY)).to eq("t" => "inf", "sign" => 1)
      expect(described_class.encode(-Float::INFINITY)).to eq("t" => "inf", "sign" => -1)
      expect(round_trip(Float::INFINITY)).to eq(Float::INFINITY)
      expect(round_trip(-Float::INFINITY)).to eq(-Float::INFINITY)
    end

    # JSON.generate raises on a binary string, which crypto and file code hits
    # constantly.
    it "base64s a binary string and records its encoding" do
      binary = [0xff, 0x00, 0xfe].pack("C*")
      tagged = described_class.encode(binary)

      expect(tagged["t"]).to eq("bin")
      expect(tagged["enc"]).to eq("ASCII-8BIT")
      expect { JSON.generate(tagged) }.not_to raise_error
    end

    it "base64s an invalidly-encoded string too" do
      invalid = "abc\xC3".dup.force_encoding("UTF-8")

      expect(described_class.encode(invalid)["t"]).to eq("bin")
    end
  end

  describe "decimals" do
    # A Float cannot represent money, and a Float round trip would silently change
    # a pinned total.
    it "is a string on the wire, under its own tag" do
      expect(described_class.decimal("19.99")).to eq("t" => "decimal", "v" => "19.99")
      expect(described_class.decode(described_class.decimal("19.99"))).to eq("19.99")
    end
  end

  describe "refs" do
    # Ids come from sequences, and sequences do not roll back.
    it "names a record the plan builds, never an id" do
      expect(described_class.ref("invoice_1")).to eq("t" => "ref", "v" => "invoice_1")
      expect(described_class.type_of(described_class.ref("x"))).to eq("ref")
    end
  end

  describe "collections" do
    it "tags every element" do
      expect(described_class.encode([1, :a])).to eq(
        "t" => "array",
        "v" => [{ "t" => "int", "v" => 1 }, { "t" => "sym", "v" => "a" }]
      )
    end

    # A Hash with symbol keys and one with string keys are different arguments.
    it "tags hash keys as well as values, preserving insertion order" do
      tagged = described_class.encode({ b: 1, a: 2 })

      expect(tagged["v"].map { |key, _| key["v"] }).to eq(%w[b a])
      expect(round_trip({ b: 1, a: 2 })).to eq(b: 1, a: 2)
    end

    it "rounds floats, so machine noise cannot make a pin unstable" do
      expect(described_class.encode(0.1 + 0.2)).to eq("t" => "float", "v" => 0.3)
    end
  end

  describe "round-tripping through JSON, which is the actual boundary" do
    [1, -1, 0, "hi", "", :sym, nil, true, false, [1, "two", :three], { a: 1 }, 1.5].each do |value|
      it "survives #{value.inspect}" do
        wire = JSON.parse(JSON.generate(described_class.encode(value)))

        expect(described_class.decode(wire)).to eq(value)
      end
    end
  end

  describe "#describe, for terminal output" do
    it "renders a ref by name and a string with quotes" do
      expect(described_class.describe(described_class.ref("invoice_1"))).to eq("invoice_1")
      expect(described_class.describe(described_class.encode("hi"))).to eq('"hi"')
      expect(described_class.describe(described_class.encode(:up))).to eq(":up")
      expect(described_class.describe(described_class.encode(nil))).to eq("nil")
    end

    it "renders collections readably" do
      expect(described_class.describe(described_class.encode([1, :a]))).to eq("[1, :a]")
    end

    it "names the values JSON cannot carry" do
      expect(described_class.describe(described_class.encode(Float::NAN))).to eq("NaN")
      expect(described_class.describe(described_class.encode(-Float::INFINITY))).to eq("-Infinity")
    end
  end

  describe "#tagged?" do
    it "recognises its own output and nothing else" do
      expect(described_class).to be_tagged(described_class.encode(1))
      expect(described_class).not_to be_tagged(1)
      expect(described_class).not_to be_tagged({ "v" => 1 })
      expect(described_class.type_of(1)).to be_nil
    end
  end
end
