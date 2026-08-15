# frozen_string_literal: true

# chatwoot's shape: the entry point is #perform, and #call appears nowhere.
class IpLookupService
  def perform(ip_address)
    Geocoder.search(ip_address).first
  end

  private

  def database_available?
    true
  end
end
