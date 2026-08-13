class BulkImporter
  def initialize(customer, *extras, **options)
    @customer = customer
    @extras = extras
    @options = options
  end

  # A splat cannot be varied, and generating a variation for one would spend a
  # case slot that dedup then throws away - so a target with splats would quietly
  # get fewer real cases.
  #
  # `number` is a string on invoices and an integer on reports, so the schema
  # cannot say what this parameter is.
  def call(number, batch_size = 100, *rest)
    [number, batch_size, rest]
  end
end
