module JSON
  class Schema
    class Validator
      attr_accessor :attributes, :formats, :uri, :names
      attr_reader :default_formats

      def initialize
        @attributes = {}
        @formats = {}
        @default_formats = {}
        @uri = nil
        @names = []
        @metaschema_name = ''
      end

      def extend_schema_definition(schema_uri)
        warn '[DEPRECATION NOTICE] The preferred way to extend a Validator is by subclassing, rather than #extend_schema_definition. This method will be removed in version >= 3.'
        validator = JSON::Validator.validator_for_uri(schema_uri)
        @attributes.merge!(validator.attributes)
      end

      def validate(current_schema, data, fragments, processor, options = {})
        # Boolean schemas, supported since draft 6, short-circuit validation:
        # `true` validates anything, `false` validates nothing.
        case current_schema.schema
        when true
          return data
        when false
          message = "The property '#{JSON::Schema::Attribute.build_fragment(fragments)}' of type #{JSON::Schema::Attribute.type_of_data(data)} is invalid for the boolean schema 'false'"
          JSON::Schema::Attribute.validation_error(processor, message, fragments, current_schema, self.class, options[:record_errors])
          return data
        end

        current_schema.schema.each do |attr_name, _attribute|
          if @attributes.has_key?(attr_name.to_s)
            @attributes[attr_name.to_s].validate(current_schema, data, fragments, processor, self, options)
          end
        end
        data
      end

      def metaschema
        resources = File.expand_path('../../../resources', __dir__)
        File.join(resources, @metaschema_name)
      end
    end
  end
end
