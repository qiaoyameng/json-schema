require 'json-schema/attribute'

module JSON
  class Schema
    class FormatAttribute < Attribute
      def self.validate(current_schema, data, fragments, processor, validator, options = {})
        return unless data_valid_for_type?(data, current_schema.schema['type'])

        format = current_schema.schema['format'].to_s
        context = options[:validation_context]
        format_validator = if context
                             context.format_for(validator, format)
                           else
                             validator.formats[format]
                           end
        format_validator&.validate(current_schema, data, fragments, processor, format_validator, options)
      end
    end
  end
end
