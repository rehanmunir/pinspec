class LocaleGreeter
  def initialize(invoice)
    @invoice = invoice
  end

  def call
    {
      greeting: I18n.t("pinspec.greeting"),
      locale: I18n.locale.to_s,
      zone: Time.zone.name,
      zoned_now: Time.zone.now.iso8601
    }
  end
end
