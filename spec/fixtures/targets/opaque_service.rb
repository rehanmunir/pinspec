# frozen_string_literal: true

class ExternalBaseService < ApplicationService
  def initialize(invoice)
    super(invoice, Rails.application.config.tax_engine)
  end

  def call
    :done
  end
end

class ContainerService
  def initialize(invoice)
    @invoice = invoice
    @engine = Container.resolve(:tax_engine)
  end

  def call
    :done
  end
end

class NoCtorService < ApplicationService
  def call
    :done
  end
end

class DefaultInjectedService
  def initialize(invoice, engine: Container.resolve(:tax_engine))
    @invoice = invoice
    @engine = engine
  end

  def call
    :done
  end
end
