# The encoding axis: one return value covering every kind section 9 describes, so
# that probe encoding and spec-host normalization are compared on all of them at
# once rather than on whichever kind a realistic target happened to use.
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
