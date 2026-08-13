FactoryBot.define do
  factory :customer do
    sequence(:name) { |n| "Customer #{n}" }
    sequence(:email) { |n| "customer#{n}@example.test" }
    region { "US" }

    # The sinks axis: this fires while the PLAN builds records, so neither host may
    # attribute it to the target. Both clear their sinks after setup.
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
