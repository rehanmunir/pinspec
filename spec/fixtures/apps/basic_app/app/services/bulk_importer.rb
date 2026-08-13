class BulkImporter
  def initialize(customer, *extras, **options)
    @customer = customer
    @extras = extras
    @options = options
  end

  def call(number, batch_size = 100, *rest)
    [number, batch_size, rest]
  end
end
