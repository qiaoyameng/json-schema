require 'json-schema/attribute'

module JSON
  class Schema
    class ContainsAttribute < Attribute
      # Maximum number of failing array items whose validation errors are
      # kept as sub-errors of the `contains` failure.
      MAX_RECORDED_SUB_ERRORS = 5

      def self.validate(current_schema, data, fragments, processor, validator, options = {})
        return unless data.is_a?(Array)

        contains_schema = JSON::Schema.new(current_schema.schema['contains'], current_schema.uri, validator)
        errors = {}
        valid = false

        data.each_with_index do |item, index|
          pre_validation_error_count = validation_errors(processor).count
          item_errors = []

          begin
            contains_schema.validate(item, fragments + [index.to_s], processor, options)
          rescue ValidationError => e
            item_errors.push(e)
          end

          diff = validation_errors(processor).count - pre_validation_error_count
          while diff.positive?
            diff -= 1
            item_errors.push(validation_errors(processor).pop)
          end

          if item_errors.empty?
            valid = true
            break
          end

          # Keep a limited number of accurately located sub-errors
          errors["contains #{index}"] = item_errors.reverse if errors.size < MAX_RECORDED_SUB_ERRORS
        end

        unless valid
          message = "The property '#{build_fragment(fragments)}' did not contain an item matching the required schema"
          validation_error(processor, message, fragments, current_schema, self, options[:record_errors])
          validation_errors(processor).last.sub_errors = errors unless errors.empty?
        end
      end
    end
  end
end
