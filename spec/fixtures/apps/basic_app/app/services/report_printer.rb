class ReportPrinter
  def initialize(report)
    @report = report
  end

  def call
    @report.title
  end
end
