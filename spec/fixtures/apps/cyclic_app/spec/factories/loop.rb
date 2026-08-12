FactoryBot.define do
  # Mutually parented factories. factory_bot itself would raise on load; pinspec
  # only reads the source, and must not hang on input that never terminates.
  factory :chicken, parent: :egg do
    name { "chicken" }
  end

  factory :egg, parent: :chicken do
    name { "egg" }
  end
end
