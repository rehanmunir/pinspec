# frozen_string_literal: true

# super(...) into a superclass that lives in another file: the effective
# constructor cannot be resolved one level up.
class ExternalBaseService < ApplicationService
  def initialize(invoice)
    super(invoice, Rails.application.config.tax_engine)
  end

  def call
    :done
  end
end

# Reaches into a container for its dependency instead of accepting one.
class ContainerService
  def initialize(invoice)
    @invoice = invoice
    @engine = Container.resolve(:tax_engine)
  end

  def call
    :done
  end
end

# No initialize of its own and an out-of-file superclass.
class NoCtorService < ApplicationService
  def call
    :done
  end
end

# A DI call in a *parameter default* is fine — the probe passes its own value,
# so the default never runs.
class DefaultInjectedService
  def initialize(invoice, engine: Container.resolve(:tax_engine))
    @invoice = invoice
    @engine = engine
  end

  def call
    :done
  end
end
