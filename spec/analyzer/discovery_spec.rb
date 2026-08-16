# frozen_string_literal: true

# M-15. Measured across five public Rails codebases, assuming #call reached 14% of
# service files - and 2% of chatwoot, whose entry points are named `perform`.
RSpec.describe Pinspec::Analyzer::Discovery do
  def fixture(name)
    File.expand_path("../fixtures/discovery/#{name}.rb", __dir__)
  end

  def choose(name, convention: nil)
    described_class.new(fixture(name)).choose(convention: convention)
  end

  describe "learning the application's own convention" do
    it "counts the name an application uses most" do
      files = %w[perform_service perform_service wrapper_service].map { |f| fixture(f) }

      expect(described_class.convention_for(files)).to eq("perform")
    end

    it "declines to call a single occurrence a convention" do
      expect(described_class.convention_for([fixture("sole_method")])).to be_nil
    end

    it "picks the convention over a conventional name when the app disagrees" do
      choice = choose("perform_service", convention: "perform")

      expect(choice.method_name).to eq("perform")
      expect(choice.reason).to eq(:convention)
    end
  end

  describe "choosing a method" do
    it "takes a conventional entry point when the app has no strong convention" do
      expect(choose("wrapper_service").method_name).to eq("call")
    end

    it "takes the only public method a class has" do
      choice = choose("sole_method")

      expect(choice.method_name).to eq("format_amount")
      expect(choice.reason).to eq(:sole_method)
    end

    it "ignores private methods entirely" do
      expect(choose("perform_service").candidates).to eq(["perform"])
    end

    it "refuses when several public methods and none is conventional" do
      choice = choose("many_methods")

      expect(choice).to be_ambiguous
      expect(choice.reason).to eq(:ambiguous)
      expect(choice.candidates).to contain_exactly("flush", "rotate", "archive")
    end

    it "reports a class with nothing public rather than guessing" do
      choice = choose("nothing_public")

      expect(choice).to be_ambiguous
      expect(choice.reason).to eq(:no_public_methods)
    end
  end

  # `def self.call(...)` delegating to `def call` is the commonest service idiom in
  # Ruby. The bare name resolves to two definitions, and refusing it cost 108 of
  # forem's 322 service files - 13% of the whole corpus.
  # Found by pinning a real directory: 10 of 20 files came back AmbiguousTarget, and
  # one of them had a single public method that pinspec was excluding outright.
  describe "a class whose public surface is a conversion method" do
    it "pins to_a when that is all the class exposes" do
      choice = choose("conversion_only", convention: "call")

      expect(choice.method_name).to eq("to_a")
      expect(choice).not_to be_ambiguous
    end

    it "still prefers a real entry point over a conversion method" do
      expect(choose("conversion_and_call", convention: "call").method_name).to eq("call")
    end

    it "keeps to_s and inspect off the table entirely" do
      expect(described_class::NON_TARGETS).to include("to_s", "inspect", "initialize")
      expect(described_class::NON_TARGETS).not_to include("to_a")
    end
  end

  describe "a class-method wrapper around an instance method" do
    subject(:choice) { choose("wrapper_service") }

    it "qualifies the instance method so it does not read as ambiguous" do
      expect(choice.descriptor).to eq("Builder#call")
    end

    it "leaves an unqualified name alone when there is no wrapper" do
      expect(choose("perform_service").descriptor).to eq("perform")
    end

    it "resolves through the parser to the instance method, not the wrapper" do
      profile = Pinspec::Analyzer::TargetParser.parse(fixture("wrapper_service"), choice.descriptor)

      expect(profile.class_name).to eq("Articles::Builder")
      expect(profile.construction_kind).to eq(:new)
      expect(profile.initializer_params.map(&:name)).to eq([:user])
    end

    it "would be ambiguous without the qualifier, which is the bug this fixes" do
      expect { Pinspec::Analyzer::TargetParser.parse(fixture("wrapper_service"), "call") }
        .to raise_error(Pinspec::AmbiguousTarget)
    end
  end
end
