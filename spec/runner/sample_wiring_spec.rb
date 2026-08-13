# frozen_string_literal: true

RSpec.describe Pinspec::Runner::Capture, "handing sampled rows to the hydrator" do
  def app
    File.expand_path("../fixtures/apps/engine_app", __dir__)
  end

  let(:profile) { Pinspec::Analyzer::AppProfileReader.read(app) }

  let(:target) do
    Pinspec::Analyzer::TargetParser.parse(File.join(app, "app/services/order_summary.rb"), "call")
  end

  let(:plan) { Pinspec::Setup::ContextBuilder.build(target: target, profile: profile) }

  let(:sampled) do
    Pinspec::Inputs::SampleRunner::Result.new(
      env: "development",
      counts: { "shop_orders" => 1 },
      rows: { "shop_orders" => [{ "id" => 7, "total" => "10.0", "shop_user_id" => 3 }] },
      stratified: {},
      errors: []
    )
  end

  subject(:capture) do
    described_class.new(app_root: app, target: target.file_path, method: "call", sample: true)
  end

  before do
    allow(Pinspec::Inputs::SampleRunner).to receive(:new).and_return(
      instance_double(Pinspec::Inputs::SampleRunner, fetch: sampled)
    )
  end

  it "hydrates the sampled row into an import cluster" do
    clusters = capture.send(:sample_imports, plan, profile, target)

    expect(clusters.size).to eq(1)
    expect(clusters.first.table).to eq("shop_orders")
  end

  it "names the model from the factory's declared class, not the table name" do
    clusters = capture.send(:sample_imports, plan, profile, target)

    expect(clusters.first.model).to eq("Shop::Order")
    expect(clusters.first.model).not_to eq("ShopOrder")
  end

  it "asks the sampler for the tables the plan's world is made of, stratified by status" do
    asked = nil
    runner = instance_double(Pinspec::Inputs::SampleRunner)
    allow(runner).to receive(:fetch) { |requests| asked = requests; sampled }
    allow(Pinspec::Inputs::SampleRunner).to receive(:new).and_return(runner)

    capture.send(:sample_imports, plan, profile, target)

    expect(asked.map { |request| request[:table] }).to eq(["shop_orders"])
    expect(asked.first[:status_column]).to eq("status")
  end

  it "drops the primary key, so a snapshot cannot carry a real row id" do
    clusters = capture.send(:sample_imports, plan, profile, target)

    expect(clusters.first.attrs.keys).not_to include("id")
  end

  it "returns nothing when the database had nothing to give" do
    empty = sampled.with(counts: { "shop_orders" => 0 }, rows: {})
    allow(Pinspec::Inputs::SampleRunner).to receive(:new).and_return(
      instance_double(Pinspec::Inputs::SampleRunner, fetch: empty)
    )

    expect(capture.send(:sample_imports, plan, profile, target)).to be_empty
  end
end
