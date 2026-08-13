# Two parameters of the same model. Binding both to one record would build a
# world where a company merges with itself.
class CompanyMerger
  def initialize(source_company, target_company)
    @source_company = source_company
    @target_company = target_company
  end

  def call
    [@source_company, @target_company]
  end
end
