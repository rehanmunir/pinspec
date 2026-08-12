FactoryBot.define do
  factory :customer, class: "Billing::Customer", aliases: [:buyer, :payer] do
    name { "Acme" }
    email { "acme@example.test" }

    factory :premium_customer do
      region { "US" }
    end
  end

  factory :product do
    sku { "SKU-1" }
    name { "Widget" }

    factory :premium_product, parent: :product do
      name { "Premium Widget" }
    end
  end

  factory :report_stub, class: "Report" do
    skip_create
    initialize_with { Report.new }
    title { "Q1" }
  end
end
