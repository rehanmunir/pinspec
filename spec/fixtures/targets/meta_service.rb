# frozen_string_literal: true

class DynamicService
  def method_missing(name, *args)
    return super unless name.to_s.start_with?("compute_")

    args
  end

  def respond_to_missing?(name, include_private = false)
    name.to_s.start_with?("compute_") || super
  end
end
