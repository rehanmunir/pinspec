# Reads the current user, which is what makes the auth and whodunnit steps
# relevant: pinspec only builds a user when the target could observe one, so a
# fixture that never mentions it cannot exercise those steps.
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
