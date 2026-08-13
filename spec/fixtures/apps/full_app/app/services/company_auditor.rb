# Schema-driven: full_app has no factories at all, so every record in this plan
# has to be built from the schema.
class CompanyAuditor
  def initialize(company)
    @company = company
  end

  def call
    return :hidden unless Flipper.enabled?(:audit_v2)

    @company.name
  end
end
