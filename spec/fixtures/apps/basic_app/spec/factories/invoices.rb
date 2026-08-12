FactoryBot.define do
  factory :invoice do
    customer
    sequence(:number) { |n| "INV-#{n}" }
    total { 100.0 }
    status { "draft" }

    trait :paid do
      paid { true }
      status { "paid" }
    end

    trait :overdue do
      due_on { 1.week.ago }
    end

    factory :paid_invoice do
      paid { true }
    end

    transient do
      line_count { 3 }
    end

    after(:create) do |invoice, evaluator|
      create_list(:line_item, evaluator.line_count, invoice: invoice)
    end
  end

  # `parent:` on a top-level factory: the only form that is not also nested, and
  # therefore the only one that proves the option is read.
  factory :discounted_invoice, parent: :invoice do
    total { 50.0 }
  end

  factory :line_item do
    invoice
    association :product, factory: :premium_product
    quantity { 1 }
    unit_price { 9.99 }
  end
end
