# frozen_string_literal: true

module Articles
  # The commonest Ruby service idiom: a class-method wrapper delegating to the
  # instance method. The bare name resolves to two definitions.
  class Builder
    def self.call(...)
      new(...).call
    end

    def initialize(user)
      @user = user
    end

    def call
      @user
    end
  end
end
