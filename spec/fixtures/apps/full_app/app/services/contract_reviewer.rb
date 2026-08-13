class ContractReviewer
  def initialize(contract)
    @contract = contract
  end

  def call
    @contract.title
  end
end
