# frozen_string_literal: true

RSpec.describe "reading a target app whose source is not ASCII" do
  def app
    File.expand_path("../fixtures/apps/utf8_app", __dir__)
  end

  around do |example|
    original = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    example.run
  ensure
    Encoding.default_external = original
  end

  # A comment strip once removed every accented byte from this fixture, leaving the
  # examples below passing over pure ASCII - testing nothing at all. The bytes now
  # live in string literals, and this holds them there.
  it "keeps its non-ASCII in code, not in comments" do
    Dir[File.join(app, "**/*.rb")].each do |file|
      bytes = File.binread(file)
      next unless bytes.each_byte.any? { |byte| byte > 127 }

      without_comments = bytes.each_line.reject { |line| line.lstrip.start_with?("#".b) }.join

      expect(without_comments.each_byte.any? { |byte| byte > 127 })
        .to be(true), "#{File.basename(file)} carries non-ASCII only in comments"
    end
  end

  it "is a fixture that would actually trigger it" do
    %w[spec/rails_helper.rb db/schema.rb app/models/producteur.rb
       spec/factories/paniers.rb config/application.rb].each do |file|
      bytes = File.binread(File.join(app, file))

      expect(bytes.each_byte.any? { |byte| byte > 127 }).to be(true), "#{file} is pure ASCII"
    end
  end

  it "confirms the naive read still breaks under this locale" do
    naive = File.read(File.join(app, "spec/rails_helper.rb"))

    expect(naive.encoding).to eq(Encoding::US_ASCII)
    expect { naive.scan(/DatabaseCleaner\.strategy\s*=\s*:(\w+)/) }
      .to raise_error(ArgumentError, /invalid byte sequence/)
  end

  describe "a file whose bytes are not valid UTF-8 at all" do
    let(:path) { File.join(app, "app/models/ancien.rb") }

    it "is a fixture that really is invalid, not merely non-ASCII" do
      expect(File.binread(path).force_encoding("UTF-8")).not_to be_valid_encoding
    end

    it "returns a string that can be matched, rather than raising" do
      source = Pinspec::Analyzer::Source.read(path)

      expect(source).to be_valid_encoding
      expect { source.match?(/default_scope/) }.not_to raise_error
      expect(source).to include("default_scope")
    end

    it "does not stop the model scan finding the other models" do
      findings = Pinspec::Analyzer::AppProfileReader.read(app).model_findings

      expect(findings.map(&:model)).to include("Producteur", "Ancien")
    end
  end

  it "reads as UTF-8 regardless of the locale" do
    source = Pinspec::Analyzer::Source.read(File.join(app, "spec/rails_helper.rb"))

    expect(source.encoding).to eq(Encoding::UTF_8)
    expect(source).to be_valid_encoding
    expect(source).to include("Montréal")
  end

  it "profiles the whole app without raising" do
    profile = Pinspec::Analyzer::AppProfileReader.read(app)

    expect(profile.db_cleaner).to eq(:truncation)
    expect(profile.isolation).to eq(:truncation)
    expect(profile.default_locale).to eq(:fr)
    expect(profile.rails_version).to eq("7.1.3.2")
  end

  it "reads the model hazards out of an accented model" do
    findings = Pinspec::Analyzer::AppProfileReader.read(app).model_findings

    expect(findings.map(&:kind)).to include(:default_scope, :after_commit)
    expect(findings.map(&:model)).to include("Producteur")
  end

  it "parses a schema whose column defaults are not ASCII" do
    schema = Pinspec::Analyzer::SchemaReader.read(app)

    expect(schema.tables.map(&:name)).to contain_exactly("producteurs", "paniers")
    expect(schema.table("producteurs").column("devise").default).to eq("€")
    expect(schema.fk_map).to include("paniers.producteur_id" => "producteurs")
  end

  it "indexes factories whose values are not ASCII" do
    index = Pinspec::Analyzer::FactoryRegistry.read(app)

    expect(index.factories.map(&:name)).to include(:producteur, :panier)
    expect(index.factory(:producteur).attribute("ville").source).to include("Montréal")
  end

  it "resolves a target whose comments and literals are not ASCII" do
    target = Pinspec::Analyzer::TargetParser.parse(
      File.join(app, "app/services/calculateur_de_panier.rb"), "call"
    )

    expect(target.class_name).to eq("CalculateurDePanier")
    expect(target.initializer_params.map(&:name)).to eq(%i[panier taux])
  end

  it "plans against the app without raising" do
    profile = Pinspec::Analyzer::AppProfileReader.read(app)
    target = Pinspec::Analyzer::TargetParser.parse(
      File.join(app, "app/services/calculateur_de_panier.rb"), "call"
    )

    plan = Pinspec::Setup::ContextBuilder.build(target: target, profile: profile)

    expect(plan.isolation).to eq(:truncation)
    expect(plan.steps_of(:set_locale).first.payload[:locale]).to eq(:fr)
  end
end
