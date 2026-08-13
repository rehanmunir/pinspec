# frozen_string_literal: true

require "json"

RSpec.describe Pinspec::Emit::Namer do
  let(:target) do
    Pinspec::Analyzer::TargetParser.parse(
      File.expand_path("../fixtures/apps/rails71_basic/app/services/invoice_calculator.rb", __dir__), "call"
    )
  end

  def input_case(id = "c001", origin: :defaults)
    Pinspec::InputCase.new(id: id, ctor_args: [], ctor_kwargs: {}, args: [], kwargs: {}, origin: origin)
  end

  def observation(status: "returned")
    {
      "status" => status,
      "return_value" => { "t" => "decimal", "v" => "110.0" },
      "error" => { "class" => "ArgumentError", "message" => "no status" },
      "enqueued_jobs" => [{ "job" => "SyncJob" }]
    }
  end

  describe "without an LLM, which is the default" do
    subject(:namer) { described_class.new(target: target) }

    it "is not enabled" do
      expect(namer).not_to be_enabled
    end

    it "names every case deterministically" do
      names = namer.describe([[input_case, observation]])

      expect(names["c001"]).to eq("call returns the pinned value (c001, defaults)")
    end

    it "names a raise as a raise" do
      names = namer.describe([[input_case, observation(status: "raised")]])

      expect(names["c001"]).to include("raises")
    end
  end

  describe "what the model is allowed to see" do
    subject(:namer) { described_class.new(target: target, enabled: true, client: ->(_p) { {} }) }

    let(:sent) do
      facts = namer.send(:facts_for, input_case, observation)

      JSON.generate(namer.payload([facts]))
    end

    it "sends no pinned value, in any form" do
      expect(sent).not_to include("110.0")
      expect(sent).not_to include("decimal")
      expect(sent).not_to include("SyncJob")
      expect(sent).not_to include("no status")
    end

    it "sends only what a name could need" do
      payload = JSON.parse(sent)["cases"].first

      expect(payload.keys).to contain_exactly("id", "origin", "outcome_kind", "method", "class", "parameter_names")
      expect(payload["outcome_kind"]).to eq("returns")
    end
  end

  describe "what comes back" do
    def naming(reply)
      described_class.new(target: target, enabled: true, client: ->(_p) { reply })
        .describe([[input_case, observation]])
    end

    it "accepts a short, plain description" do
      names = naming({ "cases" => [{ "id" => "c001", "description" => "with the default tax rate" }] })

      expect(names["c001"]).to eq("with the default tax rate (c001)")
    end

    it "discards a description that is trying to be a value" do
      [
        "returns 110.0",
        "expect(result).to eq(5)",
        "the total is 12345"
      ].each do |attempt|
        names = naming({ "cases" => [{ "id" => "c001", "description" => attempt }] })

        expect(names["c001"]).to include("c001, defaults"), "accepted #{attempt.inspect}"
      end
    end

    it "discards a description that quotes values back as prose" do
      names = naming({ "cases" => [{ "id" => "c001",
                                     "description" => 'returns "committed" when the status is "paid"' }] })

      expect(names["c001"]).to include("c001, defaults")
    end

    it "still allows one quoted term, since a name may legitimately need one" do
      names = naming({ "cases" => [{ "id" => "c001", "description" => 'the "default" path' }] })

      expect(names["c001"]).to eq('the "default" path (c001)')
    end

    it "discards a description containing a serializer tag or a hash rocket" do
      names = naming({ "cases" => [{ "id" => "c001", "description" => '{"t" => "decimal"}' }] })

      expect(names["c001"]).to include("c001, defaults")
    end

    it "discards an over-long description" do
      names = naming({ "cases" => [{ "id" => "c001", "description" => "x" * 200 }] })

      expect(names["c001"]).to include("c001, defaults")
    end

    it "ignores a case id it was never given" do
      names = naming({ "cases" => [{ "id" => "c999", "description" => "invented" }] })

      expect(names).not_to have_key("c999")
    end

    it "falls back silently when the service fails, because naming is not the job" do
      namer = described_class.new(target: target, enabled: true, client: ->(_p) { raise "503" })

      expect(namer.describe([[input_case, observation]])["c001"]).to include("c001, defaults")
    end

    it "falls back when the reply is not even JSON" do
      expect(naming("not json at all")["c001"]).to include("c001, defaults")
    end
  end
end
