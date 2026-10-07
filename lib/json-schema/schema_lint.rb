require 'json-schema/validator'

module JSON
  # SchemaLint is a standalone linter for JSON schema documents. It never
  # touches the normal validation path: JSON::Validator.validate and friends
  # behave exactly as before. The linter walks a schema document, aware of
  # which positions hold subschemas and which hold plain JSON data, and
  # reports unknown keywords (with spelling suggestions), deprecated keywords
  # and obvious misplacements for the selected dialect.
  module SchemaLint
    # Keywords that are valid in schema position for every dialect supported
    # by this library, in addition to the ones a validator has attributes
    # for. Their values are plain data and are never traversed.
    ANNOTATION_KEYWORDS = %w[$schema $id id title description default definitions].freeze

    # Declares which positions inside a keyword value are themselves
    # subschemas. Everything not listed here is treated as plain JSON data.
    SUBSCHEMA_POSITIONS = {
      'properties' => :map,
      'patternProperties' => :map,
      'definitions' => :map,
      'dependencies' => :dependencies,
      'items' => :self_or_array,
      'additionalItems' => :self,
      'additionalProperties' => :self,
      'contains' => :self,
      'propertyNames' => :self,
      'not' => :self,
      'allOf' => :array,
      'anyOf' => :array,
      'oneOf' => :array,
      'extends' => :self_or_array,
      'type' => :inline_schema,
      'disallow' => :inline_schema,
      'links' => :links,
    }.freeze

    # Hyper-schema link description objects carry subschemas under these keys.
    LINK_SUBSCHEMA_KEYS = %w[schema targetSchema submissionSchema hrefSchema].freeze

    # Positions an extension keyword may declare for its value.
    EXTENSION_POSITIONS = %i[none self array self_or_array map dependencies].freeze

    # Keywords that are valid for a dialect but not backed by a validator
    # attribute in this library.
    EXTRA_KEYWORDS = {
      'JSON::Schema::Draft6' => %w[$id examples contains],
      'JSON::Schema::HyperDraft6' => %w[$id examples contains links media readOnly],
      'JSON::Schema::HyperDraft4' => %w[links media readOnly],
      'JSON::Schema::HyperDraft3' => %w[links media readOnly],
      'JSON::Schema::HyperDraft2' => %w[links media],
      'JSON::Schema::HyperDraft1' => %w[links media],
    }.freeze

    DRAFT4_FAMILIES = %w[JSON::Schema::Draft4 JSON::Schema::HyperDraft4].freeze
    DRAFT6_FAMILIES = %w[JSON::Schema::Draft6 JSON::Schema::HyperDraft6].freeze
    DRAFT4_PLUS_FAMILIES = (DRAFT4_FAMILIES + DRAFT6_FAMILIES).freeze

    DEPRECATED_KEYWORDS = DRAFT4_PLUS_FAMILIES.each_with_object({}) do |family, table|
      table[family] = {
        'extends' => '"extends" is deprecated in this dialect; use "allOf" and/or "$ref" instead',
        'disallow' => '"disallow" is a draft-03 leftover in this dialect; use "not" instead',
      }
    end.freeze

    class Entry
      SEVERITIES = {
        unknown_keyword: :warning,
        deprecated_keyword: :warning,
        misplaced_keyword: :error,
        ref_cycle: :error,
        unknown_dialect: :error,
        ref: :info,
      }.freeze

      attr_reader :type, :path, :keyword, :message, :suggestion, :references

      def initialize(type:, path:, message:, keyword: nil, suggestion: nil, references: [])
        @type = type
        @path = path
        @keyword = keyword
        @message = message
        @suggestion = suggestion
        @references = references
      end

      def severity
        SEVERITIES.fetch(type)
      end

      def to_h
        {
          type: type,
          severity: severity,
          path: path,
          keyword: keyword,
          message: message,
          suggestion: suggestion,
          references: references,
        }
      end
    end

    class Report
      include Enumerable

      attr_reader :dialect

      def initialize(dialect)
        @dialect = dialect
        @entries = []
      end

      def add(entry)
        @entries << entry
      end

      def entries
        @entries.dup
      end

      def each(&block)
        @entries.each(&block)
      end

      def empty?
        @entries.empty?
      end

      def errors
        entries.select { |entry| entry.severity == :error }
      end

      def warnings
        entries.select { |entry| entry.severity == :warning }
      end

      def infos
        entries.select { |entry| entry.severity == :info }
      end

      def to_a
        entries.map(&:to_h)
      end
    end

    @extension_keywords = {}

    class << self
      # Lint a schema document against the dialect selected by the :version
      # option, the schema's own "$schema" keyword, or the library default.
      # Returns a Report; the document is never modified.
      def lint(schema, version: nil)
        validator = resolve_validator(schema, version)
        unless validator
          report = Report.new(nil)
          report.add(Entry.new(
                       type: :unknown_dialect,
                       path: '#',
                       message: 'cannot determine the schema dialect; ' \
                                'skipping keyword and spelling checks'
                     ))
          return report
        end

        report = Report.new(validator.names.first)
        Linter.new(validator, schema, report).lint
        report
      end

      # Register an extension keyword so it is not reported as unknown.
      # `subschemas` declares which positions inside its value are themselves
      # subschemas: :none (default), :self, :array, :self_or_array, :map or
      # :dependencies.
      def register_keyword(name, subschemas: :none)
        unless EXTENSION_POSITIONS.include?(subschemas)
          raise ArgumentError, "unknown subschema position #{subschemas.inspect}"
        end

        extension_keywords[name.to_s] = subschemas
      end

      def deregister_keyword(name)
        extension_keywords.delete(name.to_s)
      end

      def extension_keywords
        @extension_keywords
      end

      private

      def resolve_validator(schema, version)
        if version
          JSON::Validator.validator_for_name(version, false)
        elsif schema.is_a?(Hash) && schema['$schema'].is_a?(String)
          JSON::Validator.validator_for_uri(schema['$schema'], false)
        else
          JSON::Validator.default_validator
        end
      end
    end

    class Linter
      def initialize(validator, root, report)
        @validator = validator
        @family = validator.class.name
        @root = root
        @report = report
        @known_keywords = known_keywords
        @deprecated = DEPRECATED_KEYWORDS.fetch(@family, {})
        @visited = {}
        @in_progress = {}
        @ref_paths = Hash.new { |hash, key| hash[key] = [] }
        @cycles_reported = {}
      end

      def lint
        lint_schema(@root, [])
        @report
      end

      private

      def known_keywords
        known = @validator.attributes.keys + ANNOTATION_KEYWORDS +
                EXTRA_KEYWORDS.fetch(@family, []) + SchemaLint.extension_keywords.keys
        known.uniq
      end

      def lint_schema(node, path, property_name: nil)
        return unless node.is_a?(Hash)

        object_id = node.object_id
        return if @visited.key?(object_id)

        @visited[object_id] = pointer(path)
        @in_progress[object_id] = true

        handle_ref(node['$ref'], path) if node['$ref'].is_a?(String)

        node.each do |key, value|
          key = key.to_s
          next if key == '$ref'

          if @known_keywords.include?(key)
            check_deprecated(key, path)
            check_placement(node, key, value, path, property_name)
            positions = position_spec_for(key)
            traverse(positions, key, value, path) if positions
          else
            report_unknown(key, path)
          end
        end

        @in_progress.delete(object_id)
      end

      def position_spec_for(key)
        SUBSCHEMA_POSITIONS[key] || extension_position_spec(key)
      end

      def extension_position_spec(key)
        positions = SchemaLint.extension_keywords[key]
        positions == :none ? nil : positions
      end

      def traverse(positions, keyword, value, path)
        case positions
        when :self
          lint_schema(value, path + [keyword]) if value.is_a?(Hash)
        when :array
          each_schema(value) { |schema, index| lint_schema(schema, path + [keyword, index]) }
        when :self_or_array
          if value.is_a?(Array)
            each_schema(value) { |schema, index| lint_schema(schema, path + [keyword, index]) }
          else
            lint_schema(value, path + [keyword])
          end
        when :map
          return unless value.is_a?(Hash)

          value.each do |name, subschema|
            lint_schema(subschema, path + [keyword, name],
                        property_name: keyword == 'properties' ? name : nil)
          end
        when :dependencies
          return unless value.is_a?(Hash)

          value.each do |name, dependency|
            lint_schema(dependency, path + [keyword, name]) if dependency.is_a?(Hash)
          end
        when :inline_schema
          if value.is_a?(Hash)
            lint_schema(value, path + [keyword])
          else
            each_schema(value) { |schema, index| lint_schema(schema, path + [keyword, index]) }
          end
        when :links
          return unless value.is_a?(Array)

          value.each_with_index do |link, index|
            next unless link.is_a?(Hash)

            LINK_SUBSCHEMA_KEYS.each do |link_key|
              lint_schema(link[link_key], path + [keyword, index, link_key]) if link[link_key].is_a?(Hash)
            end
          end
        end
      end

      def each_schema(value)
        return unless value.is_a?(Array)

        value.each_with_index do |element, index|
          yield element, index if element.is_a?(Hash)
        end
      end

      def handle_ref(ref, path)
        ref_path = pointer(path + ['$ref'])
        target, segments = resolve_local_ref(ref)

        if target.is_a?(Hash)
          @report.add(Entry.new(
                        type: :ref,
                        path: ref_path,
                        message: "reference to #{pointer(segments)}"
                      ))
          follow_ref(target, segments, ref_path)
        else
          @report.add(Entry.new(
                        type: :ref,
                        path: ref_path,
                        message: "reference to #{ref.inspect} (not resolved locally)"
                      ))
        end
      end

      def follow_ref(target, segments, ref_path)
        object_id = target.object_id
        @ref_paths[object_id] << ref_path

        if @in_progress[object_id]
          report_cycle(object_id)
        elsif !@visited.key?(object_id)
          lint_schema(target, segments)
        end
      end

      def report_cycle(object_id)
        return if @cycles_reported[object_id]

        @cycles_reported[object_id] = true
        @report.add(Entry.new(
                      type: :ref_cycle,
                      path: @visited[object_id],
                      keyword: '$ref',
                      message: 'circular $ref chain; the definition is linted once',
                      references: @ref_paths[object_id].dup
                    ))
      end

      def resolve_local_ref(ref)
        return [nil, nil] unless ref.start_with?('#')

        fragment = ref[1..]
        return [@root, []] if fragment.nil? || fragment.empty?
        return [nil, nil] unless fragment.start_with?('/')

        segments = fragment.split('/')[1..].map do |segment|
          segment.gsub('~1', '/').gsub('~0', '~')
        end
        target = segments.reduce(@root) do |node, segment|
          case node
          when Hash then node[segment]
          when Array then node[segment.to_i] if segment.match?(/\A\d+\z/)
          end
        end
        [target, segments]
      end

      def check_deprecated(key, path)
        return unless @deprecated.key?(key)

        @report.add(Entry.new(
                      type: :deprecated_keyword,
                      path: pointer(path + [key]),
                      keyword: key,
                      message: @deprecated[key]
                    ))
      end

      def check_placement(node, key, value, path, property_name)
        case key
        when 'required'
          check_boolean_required(value, path, property_name)
        when 'exclusiveMinimum'
          check_exclusive(node, 'minimum', value, path)
        when 'exclusiveMaximum'
          check_exclusive(node, 'maximum', value, path)
        when 'additionalItems'
          check_additional_items(node, path)
        end
      end

      def check_boolean_required(value, path, property_name)
        return unless DRAFT4_PLUS_FAMILIES.include?(@family)
        return unless value == true || value == false

        suggestion = if property_name
                       "add #{property_name.inspect} to the parent schema's \"required\" array instead"
                     else
                       'use an array of property names on the object schema instead'
                     end
        @report.add(Entry.new(
                      type: :misplaced_keyword,
                      path: pointer(path + ['required']),
                      keyword: 'required',
                      message: '"required" with a boolean value is draft-03 style; ' \
                               'in this dialect it must be an array of property names',
                      suggestion: suggestion
                    ))
      end

      def check_exclusive(node, base, value, path)
        key = "exclusive#{base.capitalize}"
        if DRAFT4_FAMILIES.include?(@family)
          return if node.key?(base)

          @report.add(Entry.new(
                        type: :misplaced_keyword,
                        path: pointer(path + [key]),
                        keyword: key,
                        message: "#{key.inspect} has no effect without #{base.inspect}",
                        suggestion: "add a #{base.inspect} keyword next to it"
                      ))
        elsif DRAFT6_FAMILIES.include?(@family) && (value == true || value == false)
          @report.add(Entry.new(
                        type: :misplaced_keyword,
                        path: pointer(path + [key]),
                        keyword: key,
                        message: "#{key.inspect} must be a number in draft-06; " \
                                 'the boolean form is draft-04 style',
                        suggestion: "replace it with a numeric #{key.inspect} limit"
                      ))
        end
      end

      def check_additional_items(node, path)
        return unless @known_keywords.include?('additionalItems')
        return if node['items'].is_a?(Array)

        @report.add(Entry.new(
                      type: :misplaced_keyword,
                      path: pointer(path + ['additionalItems']),
                      keyword: 'additionalItems',
                      message: '"additionalItems" has no effect unless "items" is an array of schemas',
                      suggestion: 'make "items" an array of schemas or remove "additionalItems"'
                    ))
      end

      def report_unknown(key, path)
        suggestion = spelling_suggestion(key)
        @report.add(Entry.new(
                      type: :unknown_keyword,
                      path: pointer(path + [key]),
                      keyword: key,
                      message: "unknown keyword #{key.inspect} for dialect #{@report.dialect}",
                      suggestion: suggestion && "did you mean #{suggestion.inspect}?"
                    ))
      end

      # Suggestions are only ever text; the document is never modified.
      def spelling_suggestion(key)
        threshold = key.length <= 4 ? 1 : 2
        best = nil
        best_distance = threshold + 1
        @known_keywords.each do |candidate|
          distance = damerau_levenshtein(key, candidate)
          next if distance.zero? || distance >= best_distance

          best = candidate
          best_distance = distance
        end
        best
      end

      def damerau_levenshtein(a, b)
        rows = a.length + 1
        cols = b.length + 1
        d = Array.new(rows) { |i| [i] + Array.new(cols - 1, 0) }
        (1...cols).each { |j| d[0][j] = j }
        (1...rows).each do |i|
          (1...cols).each do |j|
            cost = a[i - 1] == b[j - 1] ? 0 : 1
            d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]
              d[i][j] = [d[i][j], d[i - 2][j - 2] + 1].min
            end
          end
        end
        d[a.length][b.length]
      end

      def pointer(segments)
        segments.each_with_object('#') do |segment, acc|
          acc << '/' << segment.to_s.gsub('~', '~0').gsub('/', '~1')
        end
      end
    end
  end
end
