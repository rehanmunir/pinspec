# frozen_string_literal: true

RSpec.describe Pinspec::Analyzer::TargetParser do
  describe ".split_target" do
    it "splits FILE#METHOD" do
      expect(described_class.split_target("app/services/foo.rb#call")).to eq(["app/services/foo.rb", "call"])
    end

    # Absent means absent. Discovery needs the file's contents and the surrounding
    # directory's convention, neither of which a string split has.
    it "reports no method when the target named none" do
      expect(described_class.split_target("app/services/foo.rb")).to eq(["app/services/foo.rb", nil])
    end

    it "keeps a qualified method" do
      expect(described_class.split_target("app/services/foo.rb#Bar.call")).to eq(["app/services/foo.rb", "Bar.call"])
    end

    it "refuses something that is neither a ruby file nor a target" do
      expect { described_class.split_target("app/services") }
        .to raise_error(ArgumentError, /must be a Ruby file/)
    end
  end

  describe "the headline shape: constructor dependencies + a zero-argument #call" do
    subject(:profile) { parse("invoice_calculator.rb", "call") }

    it "resolves the class and method" do
      expect(profile.class_name).to eq("InvoiceCalculator")
      expect(profile.method_name).to eq(:call)
      expect(profile.qualified_name).to eq("InvoiceCalculator#call")
      expect(profile.visibility).to eq(:public)
    end

    it "reads the constructor the method needs, which v0.2 could not see at all" do
      expect(profile.construction_kind).to eq(:new)
      expect(profile.needs_subject?).to be(true)
      expect(profile.initializer_params.map(&:name)).to eq(%i[invoice tax_engine rounding])
    end

    it "records parameter kinds and default *source*, never evaluated values" do
      expect(param(profile.initializer_params, :invoice).kind).to eq(:req)
      expect(param(profile.initializer_params, :invoice).default_source).to be_nil

      tax_engine = param(profile.initializer_params, :tax_engine)
      expect(tax_engine.kind).to eq(:key)
      expect(tax_engine.default_source).to eq("TaxEngine.new")

      expect(param(profile.initializer_params, :rounding).default_source).to eq(":up")
    end

    it "guesses a model from the parameter name when there is nothing better" do
      expect(param(profile.initializer_params, :invoice).type_hint).to eq("Invoice")
    end

    it "prefers the default literal over the name, which is the more reliable signal" do
      expect(param(profile.initializer_params, :rounding).type_hint).to eq("Symbol")
      expect(param(profile.initializer_params, :tax_engine).type_hint).to eq("TaxEngine")
    end

    it "has no method parameters — the whole point of the shape" do
      expect(profile.params).to be_empty
      expect(profile.input_params.map(&:name)).to eq(%i[invoice tax_engine rounding])
    end

    it "reports a source_range exact to the def...end span" do
      span = source_span("invoice_calculator.rb", profile.source_range)

      expect(span).to start_with("  def call")
      expect(span.strip).to end_with("end")
      expect(span).to include("Invoice.create!")
      expect(span).not_to include("def tax")
      expect(span).not_to include("def initialize")
    end

    it "collects referenced constants from the method and the constructor" do
      expect(profile.referenced_constants).to eq(%w[Invoice TaxEngine])
    end

    it "is not clock-dependent" do
      expect(profile.clock_sites).to be_empty
      expect(profile.clock_dependent?).to be(false)
    end
  end

  describe "construction_kind — all six shapes (row 29)" do
    it "resolves :class_method for def self.x, and needs no subject" do
      profile = parse("class_methods.rb", "Reconciler.call")

      expect(profile.class_name).to eq("Billing::Reconciler")
      expect(profile.construction_kind).to eq(:class_method)
      expect(profile.initializer_params).to be_empty
      expect(profile.needs_subject?).to be(false)
      expect(profile.singleton?).to be(true)
      expect(profile.qualified_name).to eq("Billing::Reconciler.call")
      expect(profile.params.map(&:name)).to eq(%i[invoice_id dry_run])
      expect(param(profile.params, :invoice_id).type_hint).to eq("Integer")
      expect(param(profile.params, :dry_run).default_source).to eq("false")
      expect(param(profile.params, :dry_run).type_hint).to eq("Boolean")
    end

    it "resolves :class_method for methods inside class << self" do
      profile = parse("class_methods.rb", "Reconciler.sweep")

      expect(profile.construction_kind).to eq(:class_method)
      expect(profile.params.map(&:name)).to eq([:period])
    end

    it "resolves :interactor from include Interactor, with the delegated context keys" do
      profile = parse("interactor_service.rb", "call")

      expect(profile.construction_kind).to eq(:interactor)
      expect(profile.initializer_params.map(&:name)).to eq(%i[invoice recipient])
      expect(profile.initializer_params.map(&:kind).uniq).to eq([:key])
    end

    it "resolves :dry_initializer from param/option declarations" do
      profile = parse("dry_service.rb", "call")

      expect(profile.construction_kind).to eq(:dry_initializer)
      expect(param(profile.initializer_params, :invoice).kind).to eq(:req)

      rate = param(profile.initializer_params, :rate)
      expect(rate.kind).to eq(:key)
      expect(rate.default_source).to eq("-> { 0.0825 }")

      expect(param(profile.initializer_params, :jurisdiction).kind).to eq(:keyreq)
    end

    it "resolves :struct from a Struct.new superclass" do
      profile = parse("struct_service.rb", "call")

      expect(profile.construction_kind).to eq(:struct)
      expect(profile.initializer_params.map(&:name)).to eq(%i[quantity unit_price])
      expect(profile.initializer_params.map(&:kind).uniq).to eq([:req])
    end

    it "resolves :model_instance for ApplicationRecord and ActiveRecord::Base" do
      expect(parse("models.rb", "total").construction_kind).to eq(:model_instance)
      expect(parse("models.rb", "amount").construction_kind).to eq(:model_instance)
      expect(parse("models.rb", "total").needs_subject?).to be(false)
    end

    it "inherits a constructor one level up when it is defined in the same file" do
      profile = parse("inherited_ctor.rb", "ShippingCalculator#call")

      expect(profile.construction_kind).to eq(:new)
      expect(profile.initializer_params.map(&:name)).to eq(%i[invoice precision])
      expect(param(profile.initializer_params, :precision).default_source).to eq("2")
    end

    it "treats a class with no superclass and no initialize as a no-arg constructor" do
      profile = parse("inherited_ctor.rb", "PlainObject#call")

      expect(profile.construction_kind).to eq(:new)
      expect(profile.initializer_params).to be_empty
    end
  end

  describe "opaque constructors — refuse instead of guessing (row 37)" do
    it "refuses super(...) into a superclass defined in another file" do
      expect { parse("opaque_service.rb", "ExternalBaseService#call") }
        .to raise_error(Pinspec::UnresolvableSetup) { |error|
          expect(error.reason).to eq(:opaque_constructor)
          expect(error.exit_code).to eq(5)
          expect(error.message).to include("super(...)")
          expect(error.message).to include("ApplicationService")
        }
    end

    it "refuses a constructor that resolves its own dependency from a container" do
      expect { parse("opaque_service.rb", "ContainerService#call") }
        .to raise_error(Pinspec::UnresolvableSetup) { |error|
          expect(error.reason).to eq(:opaque_constructor)
          expect(error.message).to include("Container.resolve(:tax_engine)")
        }
    end

    # A class with no #initialize does not have an unreadable constructor - it has
    # the default one. The commonest shape in real applications is a service that
    # inherits behaviour and takes its dependencies as method arguments, and
    # refusing it cost 88% of one real codebase's service directory.
    it "constructs a class with no initialize, noting that the ancestor was unreadable" do
      profile = parse("opaque_service.rb", "NoCtorService#call")

      expect(profile.construction_kind).to eq(:new)
      expect(profile.initializer_params).to be_empty
      expect(profile.construction_source).to eq(:assumed)
    end

    # The refusal that must survive: an #initialize that EXISTS and cannot be read.
    it "still refuses when a constructor exists but resolves its own dependencies" do
      expect { parse("opaque_service.rb", "ContainerService#call") }
        .to raise_error(Pinspec::UnresolvableSetup) { |e| expect(e.reason).to eq(:opaque_constructor) }
    end

    it "accepts a dependency injected as a parameter default, which pinspec overrides" do
      profile = parse("opaque_service.rb", "DefaultInjectedService#call")

      expect(profile.construction_kind).to eq(:new)
      expect(param(profile.initializer_params, :engine).default_source)
        .to eq("Container.resolve(:tax_engine)")
    end
  end

  describe "block-taking targets — clean refusal (row 27)" do
    it "refuses a method that yields, naming the line" do
      expect { parse("block_service.rb", "each_invoice") }
        .to raise_error(Pinspec::BlockRequired) { |error|
          expect(error.exit_code).to eq(4)
          expect(error.message).to match(/yields \(line \d+\)/)
        }
    end

    it "refuses a method taking an explicit block parameter" do
      expect { parse("block_service.rb", "with_logging") }
        .to raise_error(Pinspec::BlockRequired, /&block/)
    end

    it "does not refuse a neighbouring method that takes no block" do
      expect(parse("block_service.rb", "plain").takes_block).to be(false)
    end

    it "uses an exit code distinct from TargetNotFound" do
      expect(Pinspec::BlockRequired.exit_code).not_to eq(Pinspec::TargetNotFound.exit_code)
    end
  end

  describe "delegation and dynamic methods — a redirect, not a dead end (row 23)" do
    it "names the delegation and says the receiver is a runtime value" do
      expect { parse("delegating_service.rb", "call") }
        .to raise_error(Pinspec::TargetNotFound) { |error|
          expect(error.exit_code).to eq(2)
          expect(error.message).to include("delegates :call to `engine`")
          expect(error.message).to include("assigned at runtime")
        }
    end

    it "guesses the conventional file when the delegation target is a constant" do
      expect { parse("delegating_service.rb", "summarize") }
        .to raise_error(Pinspec::TargetNotFound) { |error|
          expect(error.message).to include("PdfRenderer")
          expect(error.message).to include("pdf_renderer.rb")
        }
    end

    it "warns that method_missing may be handling the name, and refuses to guess" do
      expect { parse("meta_service.rb", "compute_total") }
        .to raise_error(Pinspec::TargetNotFound, /defines method_missing/)
    end

    it "lists the methods it did find" do
      expect { parse("invoice_calculator.rb", "nope") }
        .to raise_error(Pinspec::TargetNotFound, /InvoiceCalculator#call/)
    end
  end

  describe "clock sites — invisible to both safety nets, so detected statically (row 35)" do
    subject(:profile) { parse("clock_service.rb", "ExpiryChecker#call") }

    it "records Time.now and Date.today with their lines" do
      expect(profile.clock_sites.map(&:call)).to eq(%w[Time.now Date.today])
      expect(profile.clock_dependent?).to be(true)

      lines = File.readlines(fixture("clock_service.rb"))
      profile.clock_sites.each do |site|
        expect(lines[site.line - 1]).to include(site.call)
      end
    end

    it "ignores zone-aware reads, which honour the plan's :set_zone step" do
      expect(profile.clock_sites.map(&:call)).not_to include("Time.zone.now", "Time.current")
    end

    it "ignores Time.new with arguments, which is a fixed instant" do
      lines = File.readlines(fixture("clock_service.rb"))
      fixed_line = lines.index { |l| l.include?("Time.new(2020") }&.succ

      expect(fixed_line).not_to be_nil, "fixture no longer contains the Time.new(2020..) case"
      expect(profile.clock_sites.map(&:line)).not_to include(fixed_line)
    end

    it "catches a clock read hiding in a parameter default" do
      profile = parse("clock_service.rb", "DefaultClockService#call")

      expect(profile.clock_sites.map(&:call)).to eq(["Time.now"])
    end
  end

  describe "ambiguity" do
    it "refuses when one name resolves to two definitions, listing both" do
      expect { parse("ambiguous.rb", "call") }
        .to raise_error(Pinspec::AmbiguousTarget) { |error|
          expect(error.exit_code).to eq(3)
          expect(error.message).to include("FirstService#call")
          expect(error.message).to include("SecondService#call")
        }
    end

    it "accepts a class-qualified target to resolve it" do
      expect(parse("ambiguous.rb", "FirstService#call").class_name).to eq("FirstService")
      expect(parse("ambiguous.rb", "SecondService#call").class_name).to eq("SecondService")
    end

    it "distinguishes an instance target from a class-method target of the same name" do
      expect(parse("class_methods.rb", "Reconciler.call").singleton?).to be(true)
      expect { parse("class_methods.rb", "Reconciler#call") }
        .to raise_error(Pinspec::TargetNotFound)
    end
  end

  describe "visibility" do
    it "tracks a bare private/public mode switch" do
      expect(parse("visibility_service.rb", "Auditor#call").visibility).to eq(:public)
      expect(parse("visibility_service.rb", "Auditor#check").visibility).to eq(:private)
      expect(parse("visibility_service.rb", "Auditor#open_check").visibility).to eq(:public)
    end

    it "tracks `private :name` applied after the definition" do
      expect(parse("visibility_service.rb", "LateVisibility#secret_a").visibility).to eq(:private)
    end

    it "tracks `private def name`, which is not a top-level statement" do
      expect(parse("visibility_service.rb", "LateVisibility#secret_b").visibility).to eq(:private)
    end

    it "does not mark class methods private because of an instance-level switch" do
      expect(parse("visibility_service.rb", "LateVisibility.build").visibility).to eq(:public)
    end
  end

  describe "parameter signatures" do
    subject(:params) { parse("signatures.rb", "SplatService#call").params }

    it "records every kind, in invocation order" do
      expect(params.map { |p| [p.name, p.kind] }).to eq(
        [
          [:a, :req],
          [:b, :opt],
          [:rest, :rest],
          [:c, :req],
          [:k, :keyreq],
          [:j, :key],
          [:opts, :keyrest]
        ]
      )
    end

    it "keeps default source text" do
      expect(param(params, :b).default_source).to eq("2")
      expect(param(params, :j).default_source).to eq("3")
    end

    it "gives splats no type hint" do
      expect(param(params, :rest).type_hint).to be_nil
      expect(param(params, :opts).type_hint).to be_nil
    end

    it "handles an endless method definition" do
      profile = parse("signatures.rb", "EndlessService#call")

      expect(profile.params.map(&:name)).to eq([:multiplier])
      expect(profile.source_range.first).to eq(profile.source_range.last)
    end

    it "qualifies deeply nested classes" do
      expect(parse("signatures.rb", "Worker#call").class_name).to eq("Nested::Deeply::Worker")
    end
  end

  describe "input handling" do
    it "splits FILE#METHOD, keeping any class qualifier with the method" do
      expect(described_class.split_target("app/services/foo.rb#Klass#call"))
        .to eq(["app/services/foo.rb", "Klass#call"])
      expect(described_class.split_target("app/services/foo.rb#call"))
        .to eq(["app/services/foo.rb", "call"])
    end

    it "leaves the method to discovery for a bare ruby file" do
      expect(described_class.split_target("app/services/foo.rb")).to eq(["app/services/foo.rb", nil])
    end

    it "rejects something that is neither a ruby file nor a target" do
      expect { described_class.split_target("app/services") }
        .to raise_error(ArgumentError, /must be a Ruby file/)
    end

    it "reports a missing file as TargetNotFound" do
      expect { parse("nope.rb", "call") }.to raise_error(Pinspec::TargetNotFound, /no such file/)
    end

    it "reports invalid Ruby as UnparsableSource, not as a missing target" do
      expect { parse("broken_source.txt", "call") }
        .to raise_error(Pinspec::UnparsableSource) { |error|
          expect(error.exit_code).to eq(1)
          expect(error.message).to include("not valid Ruby")
        }
    end
  end

  describe "exit-code taxonomy (spec v0.3 §5.1)" do
    {
      Pinspec::UnparsableSource        => 1,
      Pinspec::TargetNotFound          => 2,
      Pinspec::AmbiguousTarget         => 3,
      Pinspec::BlockRequired           => 4,
      Pinspec::UnresolvableSetup       => 5,
      Pinspec::SchemaFormatUnsupported => 6,
      Pinspec::ProbeFailure            => 7,
      Pinspec::NothingStableToPin      => 8,
      Pinspec::VerifyFailed            => 9,
      Pinspec::UnsupportedRailsVersion => 10,
      Pinspec::PinspecInternalError    => 12
    }.each do |klass, code|
      it "maps #{klass.name.split('::').last} to #{code}" do
        expect(klass.exit_code).to eq(code)
      end
    end

    it "rejects an unknown UnresolvableSetup reason" do
      expect { Pinspec::UnresolvableSetup.new(:made_up) }.to raise_error(ArgumentError)
    end
  end
end
