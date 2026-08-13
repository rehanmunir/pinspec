# The locale and zone axes. The fixture's rails_helper deliberately sets a
# DIFFERENT locale and zone for the whole suite, so these values only match the
# capture if the emitted spec forces the plan's answer back.
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
