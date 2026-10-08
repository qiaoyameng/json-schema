require 'json-schema/attribute'

module JSON
  class Schema
    # "then" and "else" are applied through the "if" attribute. They are
    # registered against the dialect so they are recognised as schema
    # keywords, but must not perform any validation on their own.
    class NoOpAttribute < Attribute
    end

    class IfThenElseAttribute < Attribute
      # The "if" keyword only selects which branch applies; its own failure is
      # never part of the final validation result.
      def self.validate(current_schema, data, fragments, processor, validator, options = {})
        schema = current_schema.schema
        return unless schema.is_a?(Hash) && schema.key?('if')

        conditional_schema = JSON::Schema.new(schema['if'], current_schema.uri, validator)
        branch = if matches?(conditional_schema, data, fragments, processor, options)
                   schema['then']
                 else
                   schema['else']
                 end

        # A missing then/else means the selected branch imposes no constraints.
        return if branch.nil?

        branch_schema = JSON::Schema.new(branch, current_schema.uri, validator)
        branch_schema.validate(data, fragments, processor, options)
      end

      def self.matches?(conditional_schema, data, fragments, processor, options)
        if options[:record_errors]
          errors_before = processor.validation_errors.clone
          conditional_schema.validate(data, fragments, processor, options)
          matched = processor.validation_errors.length == errors_before.length
          processor.validation_errors.replace(errors_before)
          matched
        else
          begin
            conditional_schema.validate(data, fragments, processor, options)
            true
          rescue ValidationError
            false
          end
        end
      end
    end
  end
end
