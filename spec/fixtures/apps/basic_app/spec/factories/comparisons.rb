FactoryBot.define do
  factory :comparison do
    before { "old.jpg" }
    after { "new.jpg" }
    caption { "Kitchen" }
  end
end

# Shapes taken verbatim from real applications. Both crashed the registry with a
# NoMethodError rather than being parsed or skipped.
FactoryBot.define do
  factory :widget do
    # Chatwoot: a block PASSED as an argument, not a block attached to the call.
    sequence(:widget_color, &:to_s)

    # Forem: factory_bot allows an array here - a factory name followed by traits.
    author factory: %i[customer premium], strategy: :create

    name { "widget" }
  end
end
