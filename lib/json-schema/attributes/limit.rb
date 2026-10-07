require 'json-schema/attribute'
require 'json-schema/errors/schema_error'
require 'json-schema/util/data_pointer'

module JSON
  class Schema
    class LimitAttribute < Attribute
      def self.validate(current_schema, data, fragments, processor, _validator, options = {})
        schema = current_schema.schema
        raw_limit = limit(schema)

        return validate_data_limit(current_schema, data, fragments, processor, options, raw_limit) if JSON::Schema::DataPointer.reference?(raw_limit)

        return unless data.is_a?(acceptable_type) && invalid?(schema, value(data))

        property    = build_fragment(fragments)
        description = error_message(schema)
        message = format("The property '%s' %s", property, description)
        validation_error(processor, message, fragments, current_schema, self, options[:record_errors])
      end

      # Validates a limit given as a { "$data" => "/pointer" } reference. The
      # pointer is resolved against the root instance of the current
      # validation run, which is carried in options[:root_data].
      def self.validate_data_limit(current_schema, data, fragments, processor, options, reference)
        unless options[:data]
          raise JSON::Schema::SchemaError, "The '#{limit_name}' constraint uses a '$data' reference, " \
                                           'but the $data extension is not enabled (pass :data => true)'
        end
        raise JSON::Schema::SchemaError, "The '$data' extension does not support the '#{limit_name}' constraint" unless JSON::Schema::DataPointer::SUPPORTED_LIMITS.include?(limit_name)

        pointer = reference['$data']
        raise JSON::Schema::SchemaError, "The '$data' reference for '#{limit_name}' must be an absolute JSON Pointer string, got #{pointer.inspect}" unless JSON::Schema::DataPointer.valid_pointer?(pointer)

        found, referenced = JSON::Schema::DataPointer.resolve(options[:root_data], pointer)

        if !found
          return data_limit_error(processor, fragments, current_schema, options, pointer, 'does not exist')
        elsif referenced.nil?
          return data_limit_error(processor, fragments, current_schema, options, pointer, 'is null')
        elsif (reason = invalid_referenced_limit(referenced))
          return data_limit_error(processor, fragments, current_schema, options, pointer, reason)
        end

        schema = current_schema.schema.merge(limit_name => referenced)
        return unless data.is_a?(acceptable_type) && invalid?(schema, value(data))

        property    = build_fragment(fragments)
        description = error_message(schema)
        message = format("The property '%s' %s", property, description)
        validation_error(processor, message, fragments, current_schema, self, options[:record_errors])
      end

      def self.data_limit_error(processor, fragments, current_schema, options, pointer, reason)
        property = build_fragment(fragments)
        message = format(
          "The property '%s' could not be validated against the '%s' constraint because the referenced data '%s' %s",
          property, limit_name, pointer, reason
        )
        validation_error(processor, message, fragments, current_schema, self, options[:record_errors])
      end

      # Returns a description of why a referenced value cannot serve as this
      # limit, or nil when the value is usable.
      def self.invalid_referenced_limit(referenced)
        referenced.is_a?(Numeric) ? nil : 'is not a number'
      end

      def self.invalid?(schema, data)
        exclusive = exclusive?(schema)
        limit = limit(schema)

        if limit_name.start_with?('max')
          exclusive ? data >= limit : data > limit
        else
          exclusive ? data <= limit : data < limit
        end
      end

      def self.limit(schema)
        schema[limit_name]
      end

      def self.exclusive?(_schema)
        false
      end

      def self.value(data)
        data
      end

      def self.acceptable_type
        raise NotImplementedError
      end

      def self.error_message(schema)
        raise NotImplementedError
      end

      def self.limit_name
        raise NotImplementedError
      end
    end
  end
end
