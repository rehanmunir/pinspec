# frozen_string_literal: true

class ReportBuilder
  delegate :call, to: :engine
  delegate :summarize, to: PdfRenderer

  def initialize(engine)
    @engine = engine
  end

  private

  attr_reader :engine
end
