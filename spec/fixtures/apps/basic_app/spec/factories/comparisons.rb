FactoryBot.define do
  factory :comparison do
    before { "old.jpg" }
    after { "new.jpg" }
    caption { "Kitchen" }
  end
end
