class KitchenSink
  def initialize(invoice)
    @invoice = invoice
  end

  def call
    {
      int: 42,
      float: 1.5,
      str: "hi",
      sym: :draft,
      nothing: nil,
      flag: true,
      decimal: BigDecimal("19.99"),
      time: Time.current,
      date: Date.current,
      array: [1, "two", :three],
      nested: { a: { b: { c: 1 } } },
      record: @invoice,
      relation: @invoice.line_items,
      binary: [255, 0, 254].pack("C*")
    }
  end
end
