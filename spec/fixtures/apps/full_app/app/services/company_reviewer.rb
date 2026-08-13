class CompanyReviewer
  def initialize(company)
    @company = company
  end

  def call
    return :forbidden unless current_user

    "#{@company.name} reviewed by #{current_user.full_name}"
  end

  private

  def current_user
    Current.user
  end
end
