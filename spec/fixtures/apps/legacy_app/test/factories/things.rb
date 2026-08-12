FactoryGirl.define do
  factory :customer do
    name "Acme"
    email "acme@example.test"
  end

  factory :invoice do
    customer
    total 100.0
    status "draft"

    trait :paid do
      paid true
    end
  end
end
