require 'json'

module JSON
  class Schema
    # Optional +$data+ extension.
    #
    # A constraint value may be declared as an object containing a +$data+
    # property whose value is an *absolute* JSON Pointer (RFC 6901), e.g.
    #
    #   { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } }
    #
    # The pointer is resolved against the original root instance of the
    # current validation run. Resolution never crosses into a +$ref+
    # target or an array item: those only change the schema and the
    # validation fragments, never the root used for pointer lookup.
    module DataReference
      DATA_KEY = '$data'.freeze
      OPTION_KEY = :$data

      # constraint keyword => expected kind of the referenced value
      KEYWORDS = {
        'maximum' => :number,
        'minimum' => :number,
        'maxLength' => :non_negative_integer,
        'maxItems' => :non_negative_integer,
      }.freeze

      ABSOLUTE_POINTER_PATTERN = %r{\A(?:/.*)?\z}.freeze
      ARRAY_INDEX_PATTERN = /\A(?:0|[1-9][0-9]*)\z/.freeze

      MISSING = :__json_schema_data_reference_missing__

      module_function

      def reference?(value)
        value.is_a?(Hash) && value.key?(DATA_KEY)
      end

      def pointer(value)
        value[DATA_KEY]
      end

      def absolute_pointer?(pointer)
        pointer.is_a?(String) && pointer.match?(ABSOLUTE_POINTER_PATTERN)
      end

      def enabled?(options)
        options[OPTION_KEY] == true
      end

      # Resolve +pointer+ (an absolute JSON Pointer) against +root+.
      #
      # Returns the referenced value, or +MISSING+ when the pointer cannot
      # be followed. It never raises and never evaluates the referenced
      # value as a schema or code.
      def resolve(root, pointer)
        tokens = pointer.split('/')[1..] || []
        tokens.reduce(root) do |node, raw_token|
          return MISSING if node.nil?

          token = unescape_token(raw_token)
          case node
          when Array
            return MISSING unless token.match?(ARRAY_INDEX_PATTERN)

            index = token.to_i
            return MISSING if index >= node.length

            node[index]
          when Hash
            return MISSING unless node.key?(token)

            node[token]
          else
            MISSING
          end
        end
      end

      # Validate +value+ for +kind+.
      #
      # Returns +[true, coerced]+ when valid, or +[false, reason_symbol]+
      # describing why the referenced value cannot be used.
      def validate_referenced_value(kind, value)
        case kind
        when :number
          if value.nil?
            [false, :null]
          elsif numeric?(value)
            [true, value]
          else
            [false, :invalid_type]
          end
        when :non_negative_integer
          if value.is_a?(Integer) && value >= 0
            [true, value]
          elsif value.nil?
            [false, :null]
          elsif value.is_a?(Integer)
            [false, :negative]
          else
            [false, :invalid_type]
          end
        else
          [false, :invalid_type]
        end
      end

      def reason_message(reason)
        case reason
        when :missing
          'references a value that does not exist'
        when :null
          'references null'
        when :invalid_pointer
          'does not contain an absolute JSON Pointer'
        when :negative
          'references a negative length'
        else
          'references a value of an invalid type'
        end
      end

      def numeric?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex)
      end

      # Return a deep copy of +metaschema+ in which the supported
      # constraint keywords also accept a +$data+ object. Returns nil when
      # the metaschema cannot express the extension.
      def augment_metaschema(metaschema)
        schema = deep_copy(metaschema)
        properties = schema['properties']
        return nil unless properties.is_a?(Hash)

        data_ref = {
          'type' => 'object',
          'required' => [DATA_KEY],
          'properties' => {
            DATA_KEY => {
              'type' => 'string',
              'pattern' => '^(?:/.*)?$',
            },
          },
        }

        KEYWORDS.each_key do |keyword|
          original = properties[keyword]
          next unless original

          properties[keyword] = {
            'anyOf' => [
              original,
              data_ref,
            ],
          }
        end

        schema
      end

      def deep_copy(value)
        JSON.parse(JSON.dump(value))
      end

      # Recursive copy of plain JSON structures (Hash/Array). Leaf values
      # are shared because they are immutable. Unlike JSON serialization
      # this never transforms the data.
      def deep_dup(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), copy| copy[k] = deep_dup(v) }
        when Array
          value.map { |item| deep_dup(item) }
        else
          value
        end
      end

      def unescape_token(token)
        token.gsub('~1', '/').gsub('~0', '~')
      end
    end
  end
end
