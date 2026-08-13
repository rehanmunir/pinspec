# frozen_string_literal: true

require Pinspec::Runner::ProbeGenerator::FACTORY_TEMPLATE

RSpec.describe PinspecFactory do
  class FlakyFactory
    attr_reader :calls

    def initialize(failures)
      @failures = failures
      @calls = 0
    end

    def create(name, attrs = nil)
      @calls += 1
      raise ActiveRecord::RecordInvalid, "Validation failed: Email is invalid" if @calls <= @failures

      { name: name, attrs: attrs, attempt: @calls }
    end
  end

  module ActiveRecord
    class RecordInvalid < StandardError; end
    class RecordNotUnique < StandardError; end
  end

  before { described_class.reset_attempts! }

  it "retries a factory that fails on a random attribute" do
    factory = FlakyFactory.new(2)

    record = described_class.create(:order, {}, factory)

    expect(record[:attempt]).to eq(3)
    expect(factory.calls).to eq(3)
  end

  it "records how many attempts it took, so a report can say the factory is fragile" do
    described_class.create(:order, {}, FlakyFactory.new(2))
    described_class.create(:customer, {}, FlakyFactory.new(0))

    expect(described_class.attempts).to eq("order" => 3, "customer" => 1)
    expect(described_class.fragile).to eq("order" => 3)
  end

  it "reports nothing fragile when every factory worked first time" do
    described_class.create(:order, {}, FlakyFactory.new(0))

    expect(described_class.fragile).to be_empty
  end

  it "is replayable, because the loop is a pure function of the seed" do
    probe_host = described_class.create(:order, {}, FlakyFactory.new(2))
    described_class.reset_attempts!
    spec_host = described_class.create(:order, {}, FlakyFactory.new(2))

    expect(spec_host).to eq(probe_host)
  end

  it "gives up and re-raises after a bounded number of attempts" do
    expect { described_class.create(:order, {}, FlakyFactory.new(99)) }
      .to raise_error(ActiveRecord::RecordInvalid, /Email is invalid/)

    expect(described_class.attempts["order"]).to eq(described_class::MAX_ATTEMPTS)
  end

  it "does not retry an error that will fail identically every time" do
    exploding = Class.new do
      attr_reader :calls
      def initialize = @calls = 0
      def create(_name, _attrs = nil)
        @calls += 1
        raise NameError, "uninitialized constant Shop::Order"
      end
    end.new

    expect { described_class.create(:order, {}, exploding) }.to raise_error(NameError)
    expect(exploding.calls).to eq(1), "retried an error that cannot be fixed by another draw"
  end

  it "passes attributes through when the plan supplies them" do
    record = described_class.create(:order, { total: 10 }, FlakyFactory.new(0))

    expect(record[:attrs]).to eq(total: 10)
  end

  it "omits the attributes argument entirely when there are none" do
    strict = Class.new do
      def create(name) = { name: name }
    end.new

    expect(described_class.create(:order, {}, strict)).to eq(name: :order)
  end

  it "says which DSL is missing rather than raising NameError" do
    expect { described_class.default_module }
      .to raise_error(/neither FactoryBot nor FactoryGirl is loaded/)
  end
end
