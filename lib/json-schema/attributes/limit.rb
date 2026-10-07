require 'json-schema/attribute'
require 'json-schema/data_reference'
require 'json-schema/errors/data_reference_error'
require 'json-schema/errors/schema_error'

module JSON
  class Schema
    class LimitAttribute < Attribute
      def self.validate(current_schema, data, fragments, processor, _validator, options = {})
        return unless data.is_a?(acceptable_type)

        limit = resolve_limit(current_schema, data, fragments, processor, options)
        return if limit == LIMIT_RESOLUTION_FAILED

        return unless invalid?(current_schema.schema, value(data), limit)

        property    = build_fragment(fragments)
        description = error_message(current_schema.schema, limit)
        message = format("The property '%s' %s", property, description)
        validation_error(processor, message, fragments, current_schema, self, options[:record_errors])
      end

      def self.invalid?(schema, data, limit = limit(schema))
        exclusive = exclusive?(schema)

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

      def self.error_message(schema, limit = limit(schema))
        raise NotImplementedError
      end

      def self.limit_name
        raise NotImplementedError
      end

      def self.referenced_kind
        DataReference::KEYWORDS[limit_name]
      end

      def self.resolve_limit(current_schema, _data, fragments, processor, options)
        raw_limit = limit(current_schema.schema)
        return raw_limit unless DataReference.reference?(raw_limit)

        unless DataReference.enabled?(options)
          raise JSON::Schema::SchemaError,
                format("'%s' at %s is a $data reference, but the $data extension is not enabled",
                       limit_name, build_fragment(fragments))
        end

        unless referenced_kind
          raise JSON::Schema::SchemaError,
                format("the $data extension does not support the '%s' constraint at %s",
                       limit_name, build_fragment(fragments))
        end

        pointer = DataReference.pointer(raw_limit)
        return data_reference_error(current_schema, fragments, processor, options, pointer, :invalid_pointer) unless DataReference.absolute_pointer?(pointer)

        referenced = DataReference.resolve(options[:root_data], pointer)
        return data_reference_error(current_schema, fragments, processor, options, pointer, :missing) if referenced == DataReference::MISSING

        valid, result = DataReference.validate_referenced_value(referenced_kind, referenced)
        return data_reference_error(current_schema, fragments, processor, options, pointer, result) unless valid

        result
      end

      def self.data_reference_error(current_schema, fragments, processor, options, pointer, reason)
        property = build_fragment(fragments)
        pointer_display = pointer.is_a?(String) ? pointer : pointer.inspect
        message = format("The %s constraint at '%s' %s (referenced data path: '%s')",
                         limit_name, property, DataReference.reason_message(reason), pointer_display)
        error = DataReferenceError.new(
          message, fragments, self, current_schema, pointer_display
        )
        if options[:record_errors]
          processor.validation_error(error)
        else
          raise error
        end
        LIMIT_RESOLUTION_FAILED
      end

      LIMIT_RESOLUTION_FAILED = :__json_schema_limit_resolution_failed__
    end
  end
end
