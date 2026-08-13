class CompanyMerger
  def initialize(source_company, target_company)
    @source_company = source_company
    @target_company = target_company
  end

  def call
    [@source_company, @target_company]
  end
end
