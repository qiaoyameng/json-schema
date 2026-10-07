module JSON
  class Schema
    # Utilities backing the optional $data constraint extension.
    #
    # When the extension is enabled (pass :data => true to the validator), the
    # maximum, minimum, maxLength and maxItems keywords may take a value of the
    # form { "$data" => "/pointer" }, where the pointer is an absolute JSON
    # Pointer (RFC 6901) that is resolved against the root instance of the
    # current validation run.
    module DataPointer
      # Limit keywords that may take a { "$data" => "/pointer" } value.
      SUPPORTED_LIMITS = %w[maximum minimum maxLength maxItems].freeze

      # An absolute JSON Pointer: either empty (the root instance) or a
      # sequence of "/token" segments where "~" only appears as ~0 or ~1.
      POINTER_PATTERN = %r{\A(?:/(?:[^/~]|~[01])*)*\z}.freeze

      # Metaschema definition for a { "$data" => "/pointer" } reference.
      DATA_REFERENCE_DEFINITION = {
        'type' => 'object',
        'properties' => {
          '$data' => {
            'type' => 'string',
            'pattern' => '^(/([^/~]|~[01])*)*$',
          },
        },
        'required' => ['$data'],
        'additionalProperties' => false,
      }.freeze

      module_function

      # Is the given schema value a $data reference?
      def reference?(value)
        value.is_a?(Hash) && value.key?('$data')
      end

      # Is the given value a well-formed absolute JSON Pointer string?
      def valid_pointer?(pointer)
        pointer.is_a?(String) && POINTER_PATTERN.match?(pointer)
      end

      # Resolves an absolute JSON Pointer against the given root instance.
      # Returns [true, value] when the pointer resolves, [false, nil] when any
      # segment is missing. The referenced value is only ever read, never
      # interpreted as a schema or executed.
      def resolve(root, pointer)
        return [false, nil] unless valid_pointer?(pointer)

        tokens = pointer.split('/')
        tokens.shift
        current = root
        tokens.each do |token|
          token = token.gsub('~1', '/').gsub('~0', '~')
          case current
          when Hash
            return [false, nil] unless current.key?(token)

            current = current[token]
          when Array
            return [false, nil] unless token.match?(/\A(?:0|[1-9]\d*)\z/)

            index = token.to_i
            return [false, nil] if index >= current.length

            current = current[index]
          else
            return [false, nil]
          end
        end
        [true, current]
      end

      # Recursive copy of a JSON-like structure, used to snapshot the instance
      # at the start of a validation run so that $data resolution always sees
      # the original input, unaffected by later mutations (e.g. inserted
      # defaults) or by other validations running concurrently.
      def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), copy| copy[key] = deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end

      # Returns a copy of the given metaschema (a path to a JSON file or an
      # already parsed hash) in which the supported limit keywords also accept
      # a { "$data" => "/pointer" } reference.
      def extend_metaschema(metaschema)
        schema = metaschema.is_a?(String) ? JSON::Validator.parse(File.read(metaschema)) : deep_copy(metaschema)
        definitions = schema['definitions'] ||= {}
        definitions['dataReference'] ||= deep_copy(DATA_REFERENCE_DEFINITION)
        wrap_limit_keywords!(schema)
        schema
      end

      def wrap_limit_keywords!(node)
        case node
        when Hash
          node.each_key do |key|
            value = node[key]
            if SUPPORTED_LIMITS.include?(key) && !reference?(value)
              node[key] = { 'anyOf' => [value, { '$ref' => '#/definitions/dataReference' }] }
            else
              wrap_limit_keywords!(value)
            end
          end
        when Array
          node.each { |item| wrap_limit_keywords!(item) }
        end
      end
    end
  end
end
