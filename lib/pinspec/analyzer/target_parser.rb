# frozen_string_literal: true

require "prism"

module Pinspec
  module Analyzer
    class TargetParser
      include Source

      MODEL_BASES = ["ApplicationRecord", "ActiveRecord::Base"].freeze

      INERT_BASES = %w[Object BasicObject].freeze

      CLOCK_CALLS = {
        "Time"     => %i[now new],
        "Date"     => %i[today],
        "DateTime" => %i[now]
      }.freeze

      VISIBILITIES = %i[public private protected].freeze

      SCALARISH_NAMES = %w[
        amount total subtotal price cost quantity qty count index number num
        name email phone title body text message description reason code type
        kind status state value key data payload options opts args params attrs
        attributes config settings id token flag mode format scope limit offset
        date time now today percent rate ratio sum size length label url path
      ].freeze

      DI_PATTERNS = [
        /\ARails\.application\.config\b/,
        /\ARails\.configuration\b/,
        /Container\b.*\.resolve\b/,
        /\AContainer\./
      ].freeze

      PRUNE_AT = [
        Prism::DefNode,
        Prism::ClassNode,
        Prism::ModuleNode,
        Prism::SingletonClassNode
      ].freeze

      Descriptor = Data.define(:class_name, :method_name, :singleton)

      Scope = Struct.new(
        :name, :node, :kind, :superclass_slice, :superclass_node, :parent,
        keyword_init: true
      )

      MethodDef = Struct.new(
        :scope_name, :name, :node, :singleton, :visibility,
        keyword_init: true
      )

      Delegation = Struct.new(:scope_name, :method, :to, :line, keyword_init: true)

      class << self
        def parse(file_path, method_name)
          new(file_path, method_name).parse
        end

        DEFAULT_METHOD = "call"

        def split_target(target)
          text = target.to_s
          return text.split("#", 2) if text.include?("#")

          unless text.end_with?(".rb")
            raise ArgumentError,
                  "target must be a Ruby file, optionally with #METHOD " \
                  "(got #{target.inspect}); e.g. app/services/invoice_calculator.rb#call"
          end

          [text, DEFAULT_METHOD]
        end
      end

      class << self
        # Keyed by application root, because a batch run builds one parser per file
        # and re-globbing the application for each would be quadratic.
        def application_sources_for(root)
          @application_sources ||= {}
          @application_sources[root] ||= begin
            dirs = %w[app lib].map { |d| File.join(root, d) }.select { |d| File.directory?(d) }
            dirs.flat_map { |dir| Dir.glob(File.join(dir, "**", "*.rb")) }.sort
          end
        end

        def application_scope_cache(root)
          @application_scopes ||= {}
          @application_scopes[root] ||= {}
        end

        # Tests and long-lived processes need a way back to a clean slate.
        def reset_application_cache!
          @application_sources = {}
          @application_scopes = {}
        end
      end

      def initialize(file_path, method_name, app_root: nil)
        @app_root   = app_root
        @file_path  = file_path
        @descriptor = parse_descriptor(method_name)
      end

      def parse
        read_source
        build_index

        mdef  = select_definition
        scope = @scopes[mdef.scope_name]

        unless scope
          raise TargetNotFound,
                "`#{@descriptor.method_name}` is defined at the top level of " \
                "#{@file_path}, not inside a class or module; pinspec has no " \
                "receiver to build."
        end

        guard_block!(mdef, scope)

        construction_kind, initializer_params = resolve_construction(scope, mdef)
        init_node = find_initialize(scope.name)

        scan = [mdef.node, init_node].compact

        TargetProfile.new(
          file_path:            @file_path,
          class_name:           scope.name,
          method_name:          mdef.name,
          params:               params_of(mdef.node),
          initializer_params:   initializer_params,
          construction_kind:    construction_kind,
          visibility:           mdef.visibility,
          takes_block:          false,
          source_range:         [mdef.node.location.start_line, mdef.node.location.end_line],
          referenced_constants: referenced_constants(scan),
          clock_sites:          clock_sites(scan),
          construction_source:  @construction_source || :own
        )
      end

      private

      def parse_descriptor(raw)
        spec = raw.to_s.sub(/\A#/, "")

        if spec.include?("#")
          klass, meth = spec.split("#", 2)
          Descriptor.new(class_name: klass, method_name: meth.to_sym, singleton: false)
        elsif spec.include?(".")
          klass, meth = spec.split(".", 2)
          Descriptor.new(class_name: klass, method_name: meth.to_sym, singleton: true)
        else
          Descriptor.new(class_name: nil, method_name: spec.to_sym, singleton: nil)
        end
      end

      def read_source
        unless File.file?(@file_path)
          raise TargetNotFound, "no such file: #{@file_path}"
        end

        @source = Source.read(@file_path)
        result  = Prism.parse(@source)

        unless result.success?
          first = result.errors.first
          raise UnparsableSource,
                "#{@file_path} is not valid Ruby: #{first.message} " \
                "(line #{first.location.start_line})"
        end

        @program = result.value
      end

      def build_index
        @scopes      = {}
        @defs        = []
        @delegations = []
        @meta_scopes = []
        @overrides   = {}

        walk_body(@program.statements, nil)

        @overrides.each do |(scope_name, name), visibility|
          @defs.each do |d|
            d.visibility = visibility if d.scope_name == scope_name && d.name == name && !d.singleton
          end
        end
      end

      def walk_body(statements, scope_name)
        mode = :public

        Array(statements&.body).each do |stmt|
          case stmt
          when Prism::ClassNode, Prism::ModuleNode
            register_scope(stmt, scope_name)
          when Prism::SingletonClassNode
            walk_singleton(stmt, scope_name)
          when Prism::DefNode
            register_def(stmt, scope_name, mode)
          when Prism::CallNode
            switched = visibility_switch(stmt)
            if switched
              mode = switched
            else
              handle_macro(stmt, scope_name)
            end
          end
        end
      end

      def register_scope(node, parent_name)
        name = [parent_name, node.constant_path.slice].compact.join("::")
        klass = node.is_a?(Prism::ClassNode)

        @scopes[name] = Scope.new(
          name:             name,
          node:             node,
          kind:             klass ? :class : :module,
          superclass_slice: klass ? node.superclass&.slice : nil,
          superclass_node:  klass ? node.superclass : nil,
          parent:           parent_name
        )

        walk_body(node.body, name)
      end

      def walk_singleton(node, scope_name)
        mode = :public

        Array(node.body&.body).each do |stmt|
          case stmt
          when Prism::DefNode
            @defs << MethodDef.new(
              scope_name: scope_name, name: stmt.name, node: stmt,
              singleton: true, visibility: mode
            )
          when Prism::CallNode
            switched = visibility_switch(stmt)
            mode = switched if switched
          end
        end
      end

      def register_def(node, scope_name, mode, forced_visibility: nil)
        singleton = !node.receiver.nil?

        if %i[method_missing respond_to_missing?].include?(node.name)
          @meta_scopes << scope_name
        end

        @defs << MethodDef.new(
          scope_name: scope_name,
          name:       node.name,
          node:       node,
          singleton:  singleton,
          visibility: forced_visibility || (singleton ? :public : mode)
        )
      end

      def visibility_switch(call)
        return nil unless call.receiver.nil?
        return nil unless VISIBILITIES.include?(call.name)
        return nil if call.arguments && !call.arguments.arguments.empty?

        call.name
      end

      def handle_macro(call, scope_name)
        return unless call.receiver.nil?

        args = Array(call.arguments&.arguments)

        if VISIBILITIES.include?(call.name) && !args.empty?
          args.each do |arg|
            case arg
            when Prism::DefNode
              register_def(arg, scope_name, call.name, forced_visibility: call.name)
            when Prism::SymbolNode
              @overrides[[scope_name, arg.unescaped.to_sym]] = call.name
            end
          end
          return
        end

        return unless call.name == :delegate

        to = delegate_target(args)
        args.grep(Prism::SymbolNode).each do |sym|
          @delegations << Delegation.new(
            scope_name: scope_name,
            method:     sym.unescaped.to_sym,
            to:         to,
            line:       call.location.start_line
          )
        end
      end

      def delegate_target(args)
        hash = args.grep(Prism::KeywordHashNode).first
        return nil unless hash

        assoc = hash.elements.grep(Prism::AssocNode).find do |a|
          a.key.is_a?(Prism::SymbolNode) && a.key.unescaped == "to"
        end
        return nil unless assoc

        value = assoc.value
        value.is_a?(Prism::SymbolNode) ? value.unescaped : value.slice
      end

      def select_definition
        candidates = @defs.select { |d| d.name == @descriptor.method_name }

        if @descriptor.class_name
          scope = resolve_named_scope(@descriptor.class_name)
          candidates = candidates.select { |d| d.scope_name == scope.name }
        end

        unless @descriptor.singleton.nil?
          candidates = candidates.select { |d| d.singleton == @descriptor.singleton }
        end

        raise not_found_error if candidates.empty?
        raise ambiguous_error(candidates) if candidates.size > 1

        candidates.first
      end

      def resolve_named_scope(name)
        return @scopes[name] if @scopes.key?(name)

        suffix = @scopes.keys.select { |k| k.end_with?("::#{name}") }
        return @scopes[suffix.first] if suffix.size == 1

        if suffix.size > 1
          raise AmbiguousTarget,
                "`#{name}` matches #{suffix.join(', ')} in #{@file_path}; " \
                "qualify it fully."
        end

        raise TargetNotFound,
              "no class or module named `#{name}` in #{@file_path}. " \
              "Found: #{@scopes.keys.join(', ')}"
      end

      def not_found_error
        method = @descriptor.method_name
        parts  = ["no method `#{method}` in #{@file_path}"]

        delegation = @delegations.find { |d| d.method == method }
        if delegation
          parts << "`#{delegation.scope_name}` delegates :#{method} to " \
                   "`#{delegation.to}` (line #{delegation.line})#{delegation_hint(delegation)}"
        end

        if @meta_scopes.any?
          parts << "#{@meta_scopes.compact.uniq.join(', ')} defines method_missing, " \
                   "so `#{method}` may be handled dynamically; pinspec cannot see " \
                   "dynamic methods and will not guess at one"
        end

        known = @defs.first(12).map { |d| "#{d.scope_name}#{d.singleton ? '.' : '#'}#{d.name} " \
                                         "(line #{d.node.location.start_line})" }
        parts << "methods found: #{known.join(', ')}" if known.any?

        TargetNotFound.new(parts.join(". "))
      end

      def delegation_hint(delegation)
        to = delegation.to.to_s
        return "" if to.empty?

        if to.match?(/\A[A-Z]/)
          file = to.gsub("::", "/").gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
          " - try the definition of #{to}, conventionally #{file}.rb"
        else
          " - `#{to}` is assigned at runtime, so pin the method on whatever class " \
            "it holds, or pin this class's caller"
        end
      end

      def ambiguous_error(candidates)
        listed = candidates.map do |d|
          sep = d.singleton ? "." : "#"
          "#{@file_path}##{d.scope_name}#{sep}#{d.name} (line #{d.node.location.start_line})"
        end

        AmbiguousTarget.new(
          "`#{@descriptor.method_name}` resolves to #{candidates.size} definitions " \
          "in #{@file_path}: #{listed.join(', ')}. Re-run with one of them."
        )
      end

      def guard_block!(mdef, scope)
        block_param = mdef.node.parameters&.block
        yield_node   = find_within(mdef.node.body, Prism::YieldNode)
        return unless block_param || yield_node

        detail =
          if block_param
            "takes a block parameter (&#{block_param.name})"
          else
            "yields (line #{yield_node.location.start_line})"
          end

        raise BlockRequired,
              "#{scope.name}##{mdef.name} #{detail}. Blocks can't cross the " \
              "probe/spec boundary; extract the block body into its own method " \
              "and pin that, or pin this method's caller."
      end

      def resolve_construction(scope, mdef)
        return [:class_method, []] if mdef.singleton
        return [:model_instance, []] if model_scope?(scope)

        members = struct_members(scope)
        return [:struct, members] if members

        return [:interactor, interactor_params(scope)] if interactor?(scope)
        return [:dry_initializer, dry_params(scope)] if dry_initializer?(scope)

        init = find_initialize(scope.name)
        if init
          guard_opaque_initialize!(scope, init)
          return [:new, params_of(init)]
        end

        inherited_construction(scope)
      end

      # A class with no #initialize is not an unreadable constructor - it is the
      # default one. The commonest shape in real applications is a service that
      # inherits behaviour and takes its dependencies as method arguments:
      #
      #   class FavouriteService < BaseService
      #     def call(account, status)
      #
      # Refusing that cost 88% of one real codebase's service directory. So the
      # superclass chain is followed through the application, and only a constructor
      # that EXISTS and cannot be read is refused.
      MAX_ANCESTOR_HOPS = 4

      def inherited_construction(scope)
        sup = scope.superclass_slice
        return [:new, []] if sup.nil? || INERT_BASES.include?(sup)

        params = ancestor_initializer_params(sup, scope)
        return params if params

        # Nothing in the chain defines one, so `new` takes no arguments. When the
        # chain left the application the assumption is unverified, and says so.
        @construction_source = @left_application ? :assumed : :inherited
        [:new, []]
      end

      # Walks up through the application. Returns [:new, params] when an ancestor
      # defines #initialize, or nil when none does.
      def ancestor_initializer_params(name, scope)
        seen = []
        current = name
        hops = 0

        while current && hops < MAX_ANCESTOR_HOPS
          break if INERT_BASES.include?(current) || seen.include?(current)

          seen << current
          hops += 1

          parent = resolve_scope_relative(current, scope) || scope_from_application(current)
          if parent.nil?
            @left_application = true
            return nil
          end

          init = find_initialize(parent.name) || initializer_in(parent)
          if init
            @construction_source = :inherited
            return [:new, params_of(init)]
          end

          current = parent.superclass_slice
        end

        nil
      end

      def guard_opaque_initialize!(scope, init)
        super_node = find_within(init.body, Prism::SuperNode)
        if super_node && super_node.arguments && !super_node.arguments.arguments.empty?
          sup    = scope.superclass_slice
          parent = sup && resolve_scope_relative(sup, scope)

          unless parent
            raise UnresolvableSetup.new(
              :opaque_constructor,
              "#{scope.name}#initialize calls `super(...)` (line " \
              "#{super_node.location.start_line}) and its superclass " \
              "#{sup || '(none detected)'} is not defined in #{@file_path}, so the " \
              "effective constructor can't be resolved one level up."
            )
          end
        end

        di = find_di_dependency(init.body)
        return unless di

        raise UnresolvableSetup.new(
          :opaque_constructor,
          "#{scope.name}#initialize resolves a dependency from `#{di[:source]}` " \
          "(line #{di[:line]}) instead of taking it as an argument, so pinspec " \
          "can't control it. Inject it as a parameter; a default value is fine, " \
          "pinspec overrides defaults."
        )
      end

      def find_di_dependency(body)
        found = nil

        walk_within(body) do |node|
          next unless node.is_a?(Prism::CallNode)
          next if found

          text = node.slice
          next unless DI_PATTERNS.any? { |re| text.match?(re) }

          found = { source: text.lines.first.strip, line: node.location.start_line }
        end

        found
      end

      def model_scope?(scope)
        sup = scope.superclass_slice
        return false unless sup

        MODEL_BASES.include?(sup) || MODEL_BASES.any? { |b| sup.end_with?("::#{b}") }
      end

      def struct_members(scope)
        node = scope.superclass_node
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless %w[Struct Data].include?(node.receiver&.slice)
        return nil unless %i[new define].include?(node.name)

        Array(node.arguments&.arguments).grep(Prism::SymbolNode).map do |sym|
          build_param(sym.unescaped.to_sym, :req, nil)
        end
      end

      def interactor?(scope)
        scope_calls(scope).any? do |call|
          call.name == :include &&
            Array(call.arguments&.arguments).any? { |a| a.slice.split("::").last == "Interactor" }
        end
      end

      def interactor_params(scope)
        @delegations
          .select { |d| d.scope_name == scope.name && d.to.to_s == "context" }
          .map { |d| build_param(d.method, :key, nil) }
      end

      def dry_initializer?(scope)
        scope_calls(scope).any? do |call|
          %i[extend include].include?(call.name) &&
            Array(call.arguments&.arguments).any? { |a| a.slice.include?("Dry::Initializer") }
        end
      end

      def dry_params(scope)
        scope_calls(scope).filter_map do |call|
          next unless %i[param option].include?(call.name)

          args = Array(call.arguments&.arguments)
          sym  = args.grep(Prism::SymbolNode).first
          next unless sym

          default = dry_default(args)

          if call.name == :param
            build_param(sym.unescaped.to_sym, default ? :opt : :req, default)
          else
            build_param(sym.unescaped.to_sym, default ? :key : :keyreq, default)
          end
        end
      end

      def dry_default(args)
        hash = args.grep(Prism::KeywordHashNode).first
        return nil unless hash

        assoc = hash.elements.grep(Prism::AssocNode).find do |a|
          a.key.is_a?(Prism::SymbolNode) && a.key.unescaped == "default"
        end

        assoc&.value&.slice
      end

      def scope_calls(scope)
        Array(scope.node.body&.body).grep(Prism::CallNode)
      end

      def find_initialize(scope_name)
        @defs.find do |d|
          d.scope_name == scope_name && d.name == :initialize && !d.singleton
        end&.node
      end

      # The superclass usually lives in another file of the same application. Finding
      # it is a search for `class <Name>` under app/ and lib/, parsed with Prism so a
      # name inside a comment or a string cannot match.
      def scope_from_application(name)
        return nil if application_root.nil?

        cache = self.class.application_scope_cache(application_root)
        return cache[name] if cache.key?(name)

        cache[name] = find_scope_in_application(name)
      end

      def find_scope_in_application(name)
        demodulized = name.split("::").last
        pattern = /^\s*class\s+(?:[\w:]+::)?#{Regexp.escape(demodulized)}\b/

        application_sources.each do |path|
          source = Source.read(path)
          next unless source.match?(pattern)

          result = Prism.parse(source)
          next unless result.success?

          found = scope_named(result.value, name, demodulized)
          return found if found
        end

        nil
      end

      # Only the files an application owns. A gem's base class is deliberately out of
      # reach: pinspec would be reading code the application cannot change.
      def application_sources
        self.class.application_sources_for(application_root)
      end

      def application_root
        return @application_root if defined?(@application_root)

        @application_root = @app_root || infer_application_root
      end

      # Walk up from the target until something that marks a Rails root appears.
      def infer_application_root
        dir = File.dirname(File.expand_path(@file_path))

        while dir != "/" && dir != File.dirname(dir)
          return dir if File.file?(File.join(dir, "Gemfile")) ||
                        File.directory?(File.join(dir, "db")) ||
                        File.file?(File.join(dir, "config", "application.rb"))

          dir = File.dirname(dir)
        end

        nil
      end

      def scope_named(root, qualified, demodulized)
        found = nil

        walk = lambda do |node, prefix|
          return if found || node.nil?

          if node.is_a?(Prism::ClassNode)
            name = [prefix, node.constant_path.slice].compact.reject(&:empty?).join("::")
            if name == qualified || node.constant_path.slice == qualified ||
               node.constant_path.slice == demodulized
              found = Scope.new(name: name, node: node, kind: :class,
                                superclass_slice: node.superclass&.slice,
                                superclass_node: node.superclass, parent: nil)
              return
            end
            prefix = name
          elsif node.is_a?(Prism::ModuleNode)
            prefix = [prefix, node.constant_path.slice].compact.reject(&:empty?).join("::")
          end

          node.compact_child_nodes.each { |child| walk.call(child, prefix) }
        end

        walk.call(root, nil)
        found
      end

      # An #initialize defined directly in a scope found elsewhere in the application.
      def initializer_in(scope)
        return nil unless scope.node.is_a?(Prism::ClassNode)

        found = nil
        walk = lambda do |node|
          return if found || node.nil?

          if node.is_a?(Prism::DefNode) && node.name == :initialize && node.receiver.nil?
            found = node
            return
          end

          node.compact_child_nodes.each { |child| walk.call(child) }
        end

        walk.call(scope.node.body)
        found
      end

      def resolve_scope_relative(name, scope)
        nesting = scope.name.split("::")

        while nesting.any?
          nesting.pop
          candidate = (nesting + [name]).join("::")
          return @scopes[candidate] if @scopes.key?(candidate)
        end

        @scopes[name]
      end

      def params_of(def_node)
        parameters = def_node.parameters
        return [] unless parameters

        out = []

        parameters.requireds.each do |node|
          out << build_param(param_name(node), :req, nil)
        end

        parameters.optionals.each do |node|
          out << build_param(param_name(node), :opt, node.value&.slice)
        end

        if parameters.rest && parameters.rest.is_a?(Prism::RestParameterNode)
          out << build_param(parameters.rest.name || :args, :rest, nil)
        end

        parameters.posts.each do |node|
          out << build_param(param_name(node), :req, nil)
        end

        parameters.keywords.each do |node|
          if node.respond_to?(:value) && node.value
            out << build_param(node.name, :key, node.value.slice)
          else
            out << build_param(node.name, :keyreq, nil)
          end
        end

        if parameters.keyword_rest.is_a?(Prism::KeywordRestParameterNode)
          out << build_param(parameters.keyword_rest.name || :options, :keyrest, nil)
        end

        out
      end

      def param_name(node)
        node.respond_to?(:name) ? node.name : node.slice.to_sym
      end

      def build_param(name, kind, default_source)
        Param.new(
          name:           name,
          kind:           kind,
          default_source: default_source,
          type_hint:      type_hint_for(name, kind, default_source)
        )
      end

      def type_hint_for(name, kind, default_source = nil)
        return nil if %i[rest keyrest].include?(kind)

        from_default = hint_from_default(default_source)
        return from_default if from_default

        s = name.to_s
        return "Boolean" if s.end_with?("?") || s.start_with?("is_", "has_")
        return "Integer" if s.end_with?("_id", "_count", "_index", "_num")
        return "Array"   if s.end_with?("_ids")
        return "Time"    if s.end_with?("_at")
        return "Date"    if s.end_with?("_on", "_date")
        return nil if SCALARISH_NAMES.include?(s)
        return nil unless s.match?(/\A[a-z][a-z0-9_]*\z/)

        camelize(s)
      end

      def hint_from_default(source)
        return nil if source.nil?

        case source.strip
        when "true", "false"          then "Boolean"
        when /\A:[A-Za-z_]/           then "Symbol"
        when /\A-?\d+\z/              then "Integer"
        when /\A-?\d+\.\d+\z/         then "Float"
        when /\A["']/                 then "String"
        when /\A(\[|%[wi]?[\[(])/     then "Array"
        when /\A\{/                   then "Hash"
        when /\A(->|lambda|proc)\b/   then "Proc"
        when /\A([A-Z][\w:]*)\.new\b/ then Regexp.last_match(1)
        end
      end

      def referenced_constants(nodes)
        found = []

        nodes.each do |root|
          walk_within(root) do |node|
            case node
            when Prism::ConstantPathNode then found << node.slice
            when Prism::ConstantReadNode then found << node.name.to_s
            end
          end
        end

        roots = found.grep(/::/).map { |c| c.split("::").first }
        found.uniq.reject { |c| !c.include?("::") && roots.include?(c) }.sort
      end

      def clock_sites(nodes)
        sites = []

        nodes.each do |root|
          walk_within(root) do |node|
            next unless node.is_a?(Prism::CallNode)

            receiver = node.receiver
            next unless receiver.is_a?(Prism::ConstantReadNode)

            allowed = CLOCK_CALLS[receiver.name.to_s]
            next unless allowed&.include?(node.name)

            next if node.arguments && !node.arguments.arguments.empty?

            sites << ClockSite.new(
              call: "#{receiver.name}.#{node.name}",
              line: node.location.start_line
            )
          end
        end

        sites.uniq { |s| [s.call, s.line] }.sort_by(&:line)
      end

      def find_within(body, klass)
        result = nil
        walk_within(body) { |node| result ||= node if node.is_a?(klass) }
        result
      end

      def walk_within(node, root: true, &block)
        return unless node
        return if !root && PRUNE_AT.any? { |k| node.is_a?(k) }

        block.call(node)
        node.compact_child_nodes.each { |child| walk_within(child, root: false, &block) }
      end
    end
  end
end
