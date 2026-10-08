require 'json-schema/attribute'

module JSON
  class Schema
    class IfThenElseAttribute < Attribute
      def self.validate(current_schema, data, fragments, processor, validator, options = {})
        if_schema = JSON::Schema.new(current_schema.schema['if'], current_schema.uri, validator)

        # The `if` schema only selects which branch to validate against.
        # Its own validation errors are discarded and never reported.
        errors_copy = processor.validation_errors.clone
        if_valid = true
        begin
          if_schema.validate(data, fragments, processor, options)
          if_valid = false if processor.validation_errors.length != errors_copy.length
        rescue ValidationError
          if_valid = false
        ensure
          processor.validation_errors.replace(errors_copy)
        end

        # Absent `then`/`else` keywords are valid by definition
        branch = if_valid ? 'then' : 'else'
        return unless current_schema.schema.key?(branch)

        branch_schema = JSON::Schema.new(current_schema.schema[branch], current_schema.uri, validator)
        branch_schema.validate(data, fragments, processor, options)
      end
    end
  end
end
