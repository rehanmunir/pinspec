# frozen_string_literal: true

# Found on the first `analyze` of the first real application (Open Food Network,
# 93 tables): pinspec crashed with `invalid byte sequence in US-ASCII` pointing at
# its own DatabaseCleaner regex, saying nothing about the file that caused it.
#
# The cause is that every file pinspec reads belongs to somebody else. `File.read`
# tags its result with the LOCALE's encoding, so with `LANG` unset that is
# US-ASCII, and the first `scan` over an accented comment raises. `LANG` is unset
# in CI containers as a matter of course - and pinspec's own :hostile verify config
# sets `LANG=C` deliberately - so this is the normal case, not the corner.
RSpec.describe "reading a target app whose source is not ASCII" do
  # A method, not a constant. A constant declared inside a `describe` block lands on
  # Object, and spec_writer_spec.rb already defines one by this name pointing at a
  # different app - so a constant here silently read the wrong fixture whenever that
  # file loaded last, and every example below passed or failed for a reason that had
  # nothing to do with encoding.
  def app
    File.expand_path("../fixtures/apps/utf8_app", __dir__)
  end

  # The condition under test. `Encoding.default_external` is what `LANG` sets, so
  # forcing it here reproduces the operator's locale without re-running rspec.
  around do |example|
    original = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    example.run
  ensure
    Encoding.default_external = original
  end

  it "is a fixture that would actually trigger it" do
    # If this fixture ever loses its non-ASCII bytes, every example below passes
    # for the wrong reason.
    %w[spec/rails_helper.rb db/schema.rb app/models/producteur.rb
       spec/factories/paniers.rb config/application.rb].each do |file|
      bytes = File.binread(File.join(app, file))

      expect(bytes.each_byte.any? { |byte| byte > 127 }).to be(true), "#{file} is pure ASCII"
    end
  end

  # The plain `File.read` that used to be in the readers, kept as a control: it
  # proves the hazard is real rather than hypothetical.
  it "confirms the naive read still breaks under this locale" do
    naive = File.read(File.join(app, "spec/rails_helper.rb"))

    expect(naive.encoding).to eq(Encoding::US_ASCII)
    expect { naive.scan(/DatabaseCleaner\.strategy\s*=\s*:(\w+)/) }
      .to raise_error(ArgumentError, /invalid byte sequence/)
  end

  # Reading as UTF-8 is not sufficient on its own. A file can contain bytes that are
  # not valid UTF-8 in any locale - a Latin-1 accent in a comment last edited in 2009 -
  # and `match?` on an invalid string raises ArgumentError rather than answering.
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

    # One bad byte in one comment must not take down a report about every model.
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

    # And gets the right answers, not merely a non-crash: the strategy that the
    # crashing scan was looking for is in the file that carries the accents.
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

  # The end-to-end shape of the original crash: `analyze` reads all of it at once.
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
