FactoryBot.define do
  # before/after photos: real column names that collide with factory_bot's
  # callback DSL. `after(:create)` is a callback; `after { ... }` is an attribute.
  factory :comparison do
    before { "old.jpg" }
    after { "new.jpg" }
    caption { "Kitchen" }
  end
end
