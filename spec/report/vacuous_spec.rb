# frozen_string_literal: true

require "tmpdir"

RSpec.describe Pinspec::Report::Summary, "vacuous pins" do
  let(:app) { File.expand_path("../fixtures/apps/rails71_basic", __dir__) }
  let(:profile) { Pinspec::Analyzer::AppProfileReader.read(app) }

  def verdict(observation)
    Pinspec::Emit::StabilityFilter::Verdict.new(case_id: "c001", stable: true, cause: nil,
                                                diff: nil, observation: observation)
  end

  def summary(observation)
    stability = Pinspec::Emit::StabilityFilter::Report.new(
      verdicts: [verdict(observation)], runs: 2, compared_fields: %w[return_value]
    )
    described_class.new(app_root: Dir.mktmpdir, profile: profile, stability: stability,
                        corpus: Pinspec::InputCorpus.new(cases: [], setup_plan: nil))
  end

  # A case that returned nothing, wrote nothing and sent nothing did run - but almost
  # any change to the target would still satisfy it. Measured on real code, these are
  # exactly the pins that score weak or worthless.
  it "names a pin that observed nothing happening" do
    rendered = summary("status" => "returned", "return_value" => { "t" => "array", "v" => [] },
                       "enqueued_jobs" => [], "mail_deliveries" => [],
                       "db_delta" => { "inserts" => 0, "updates" => 0, "deletes" => 0 }).render

    expect(rendered).to include("observed nothing happening")
    expect(rendered).to include("--sample")
  end

  it "says nothing when the target actually did something" do
    rendered = summary("status" => "returned", "return_value" => { "t" => "array", "v" => [] },
                       "enqueued_jobs" => [], "mail_deliveries" => [],
                       "db_delta" => { "inserts" => 1, "updates" => 0, "deletes" => 0 }).render

    expect(rendered).not_to include("observed nothing happening")
  end

  it "says nothing when a value was returned" do
    rendered = summary("status" => "returned", "return_value" => { "t" => "int", "v" => 42 },
                       "enqueued_jobs" => [], "mail_deliveries" => [],
                       "db_delta" => { "inserts" => 0, "updates" => 0, "deletes" => 0 }).render

    expect(rendered).not_to include("observed nothing happening")
  end
end
