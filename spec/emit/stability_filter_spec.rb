# frozen_string_literal: true

# M-08 acceptance, spec v0.3 §7. The declared field set is the substance: v0.2's
# "deep-compare" would have let `duration_ms` (never equal) and SQL fingerprints
# (the most fragile field, and opt-in for pinning) decide the fate of every pin.
RSpec.describe Pinspec::Emit::StabilityFilter do
  def run(number, observations)
    Pinspec::Runner::Sandbox::Result.new(
      run: number, observations: observations, env: { "shuffle_seed" => number.to_s },
      plan_id: "abc123", stderr: ""
    )
  end

  def observation(id, **overrides)
    {
      "case_id" => id,
      "status" => "returned",
      "return_value" => { "t" => "int", "v" => 1 },
      "error" => nil,
      "setup_error" => nil,
      "enqueued_jobs" => [],
      "mail_deliveries" => [],
      "sql_fingerprints" => ["SELECT ? FROM t"],
      "db_delta" => { "inserts" => 0, "updates" => 0, "deletes" => 0 },
      "flags" => [],
      "duration_ms" => 7
    }.merge(overrides)
  end

  def filter(first, second, **options)
    described_class.new(**options).filter([run(1, first), run(2, second)])
  end

  describe "what gets compared" do
    it "ignores duration_ms, which is never equal between runs" do
      report = filter([observation("c001", "duration_ms" => 7)],
                      [observation("c001", "duration_ms" => 993)])

      expect(report.stable.map(&:case_id)).to eq(["c001"])
    end

    it "ignores SQL fingerprints unless SQL pins were asked for" do
      report = filter([observation("c001", "sql_fingerprints" => ["SELECT a"])],
                      [observation("c001", "sql_fingerprints" => ["SELECT a", "SELECT b"])])

      expect(report.stable.size).to eq(1)
      expect(report.compared_fields).not_to include("sql_fingerprints")
    end

    it "compares them when asked" do
      report = filter([observation("c001", "sql_fingerprints" => ["SELECT a"])],
                      [observation("c001", "sql_fingerprints" => ["SELECT a", "SELECT b"])],
                      compare_sql: true)

      expect(report.unstable.size).to eq(1)
      expect(report.compared_fields).to include("sql_fingerprints")
    end

    it "compares side effects, which are pins in their own right" do
      report = filter([observation("c001", "enqueued_jobs" => [{ "job" => "SyncJob" }])],
                      [observation("c001", "enqueued_jobs" => [])])

      expect(report.unstable.size).to eq(1)
    end
  end

  describe "causes, because unstable without a cause is an accusation" do
    it "calls a changed integer identity churn" do
      # Sequences are not transactional: a rolled-back case still advances them.
      report = filter([observation("c001", "return_value" => { "t" => "int", "v" => 3 })],
                      [observation("c001", "return_value" => { "t" => "int", "v" => 4 })])

      expect(report.unstable.first.cause).to eq(:identity_churn)
    end

    it "recognises a churning GlobalID as the same thing" do
      report = filter([observation("c001", "return_value" => { "t" => "gid", "model" => "Invoice", "v" => "1" })],
                      [observation("c001", "return_value" => { "t" => "gid", "model" => "Invoice", "v" => "2" })])

      expect(report.unstable.first.cause).to eq(:identity_churn)
    end

    it "calls a changed timestamp a clock problem" do
      report = filter([observation("c001", "return_value" => { "t" => "time", "v" => "2026-01-01T00:00:00Z" })],
                      [observation("c001", "return_value" => { "t" => "time", "v" => "2026-01-02T00:00:00Z" })])

      expect(report.unstable.first.cause).to eq(:time)
    end

    it "calls a tiny float difference noise rather than a behaviour change" do
      report = filter([observation("c001", "return_value" => { "t" => "float", "v" => 1.0 })],
                      [observation("c001", "return_value" => { "t" => "float", "v" => 1.0000000001 })])

      expect(report.unstable.first.cause).to eq(:float_noise)
    end

    it "quarantines a case whose world could not be built" do
      # The plan is the problem, not the target.
      broken = observation("c001", "status" => "setup_error",
                                   "setup_error" => { "error" => { "class" => "ActiveRecord::RecordInvalid", "message" => "Email taken" } })

      report = filter([broken], [broken])

      expect(report.unstable.first.cause).to eq(:setup_error)
      expect(report.unstable.first.diff).to include("Email taken")
    end

    it "excludes a case that escaped its transaction" do
      escaped = observation("c001", "flags" => ["escaped_transaction"])

      expect(filter([escaped], [escaped]).unstable.first.cause).to eq(:escaped_transaction)
    end

    it "notices a case missing from the second run entirely" do
      report = filter([observation("c001")], [])

      expect(report.unstable.first.cause).to eq(:missing_from_run)
    end
  end

  describe "the report" do
    it "counts causes, so a run that pins nothing can say why" do
      report = filter(
        [observation("c001", "return_value" => { "t" => "int", "v" => 1 }), observation("c002")],
        [observation("c001", "return_value" => { "t" => "int", "v" => 2 }), observation("c002")]
      )

      expect(report.causes).to eq(identity_churn: 1)
      expect(report.stable.map(&:case_id)).to eq(["c002"])
      expect(report).not_to be_nothing_to_pin
    end

    it "knows when there is nothing to stand behind" do
      report = filter([observation("c001", "return_value" => { "t" => "int", "v" => 1 })],
                      [observation("c001", "return_value" => { "t" => "int", "v" => 2 })])

      expect(report).to be_nothing_to_pin
    end

    it "caps the diff, because a diff nobody reads is the same as none" do
      long = (1..40).map { |n| { "t" => "int", "v" => n } }
      other = (1..40).map { |n| { "t" => "int", "v" => n + 100 } }

      report = filter([observation("c001", "return_value" => { "t" => "array", "v" => long })],
                      [observation("c001", "return_value" => { "t" => "array", "v" => other })])

      expect(report.unstable.first.diff.lines.size).to be <= described_class::MAX_DIFF_LINES
    end

    it "names the field that differed" do
      report = filter([observation("c001", "status" => "returned")],
                      [observation("c001", "status" => "raised")])

      expect(report.unstable.first.diff).to include("field: status")
    end
  end
end
