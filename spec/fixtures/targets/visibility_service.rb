# frozen_string_literal: true

class Auditor
  def call
    check
  end

  private

  def check
    :ok
  end

  public

  def open_check
    :ok
  end
end

class LateVisibility
  def secret_a
    :a
  end
  private :secret_a

  private def secret_b
    :b
  end

  def self.build
    new
  end
end
