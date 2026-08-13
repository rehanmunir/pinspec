FactoryBot.define do
  factory :chicken, parent: :egg do
    name { "chicken" }
  end

  factory :egg, parent: :chicken do
    name { "egg" }
  end
end
