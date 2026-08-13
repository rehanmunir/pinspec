# frozen_string_literal: true

# The template both hosts share. Loaded here as plain Ruby - it is held to a Ruby 2.6
# syntax floor because it runs in the target app's Ruby, so it cannot use anything
# pinspec's own code may.
require Pinspec::Runner::ProbeGenerator::FACTORY_TEMPLATE

RSpec.describe PinspecFactory do
  # Stands in for FactoryBot: fails a given number of times with the error a random
  # attribute produces, then succeeds. Nothing else about factory_bot matters here.
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

  # A stand-in for the error class, since ActiveRecord is not loaded in pinspec's own
  # suite. The template checks for it by name through `defined?`.
  module ActiveRecord
    class RecordInvalid < StandardError; end
    class RecordNotUnique < StandardError; end
  end

  before { described_class.reset_attempts! }

  # Why this exists at all: Open Food Network's `:user` factory draws an email from
  # FFaker and roughly one in three is rejected by the app's own validation. Its suite
  # tolerates that because each run draws different values. pinspec pins srand(42), so
  # "usually passes" became "always fails" - the first two attempts raised and the
  # third succeeded, every single run.
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

  # The reason retrying does not cost determinism, which is what makes it sound: both
  # hosts start from the same seed, run the same loop, consume the same random values,
  # fail on the same attempts, and end up with the same record.
  it "is replayable, because the loop is a pure function of the seed" do
    probe_host = described_class.create(:order, {}, FlakyFactory.new(2))
    described_class.reset_attempts!
    spec_host = described_class.create(:order, {}, FlakyFactory.new(2))

    expect(spec_host).to eq(probe_host)
  end

  # A factory that is broken rather than unlucky must produce its own error, not a
  # timeout and not a retry loop that hides the message.
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
    # A factory whose `create` takes only a name must still work.
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
