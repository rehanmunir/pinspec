FactoryBot.define do
  factory :customer do
    sequence(:name) { |n| "Customer #{n}" }
    sequence(:email) { |n| "customer#{n}@example.test" }
    region { "US" }

    after(:create) do |customer|
      SyncJob.perform_later(customer.id, "factory-callback")
    end
  end

  factory :invoice do
    customer
    sequence(:number) { |n| "INV-#{n}" }
    total { 100.0 }
    status { "draft" }
  end
end
