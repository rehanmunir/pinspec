# frozen_string_literal: true

FactoryBot.define do
  # The declared class is the fact that crosses the engine prefix: `:order` is a
  # Shop::Order, whose table is shop_orders.
  factory :order, class: Shop::Order do
    total { 10.0 }
    shop_user
  end

  factory :user, class: Shop::User do
    email { "pinspec@example.test" }
  end

  factory :shop_user, class: Shop::User do
    email { "owner@example.test" }
  end
end
