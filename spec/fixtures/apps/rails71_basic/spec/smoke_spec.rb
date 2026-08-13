require "rails_helper"

RSpec.describe "the fixture app's own suite" do
  it "boots and can use a factory" do
    expect(create(:customer)).to be_persisted
  end
end
