require 'json-schema/attribute'

module JSON
  class Schema
    class ContainsAttribute < Attribute
      # Only the errors from the first few non-matching items are retained so
      # that a failure against a large array does not produce unbounded output.
      MAX_RETAINED_ITEM_ERRORS = 5

      def self.validate(current_schema, data, fragments, processor, validator, options = {})
        return unless data.is_a?(Array)

        contains_schema = JSON::Schema.new(current_schema.schema['contains'], current_schema.uri, validator)
        item_errors = {}
        retained = 0
        matched = false

        data.each_with_index do |item, index|
          break if matched

          pre_validation_error_count = validation_errors(processor).count

          begin
            contains_schema.validate(item, fragments + [index.to_s], processor, options)
            item_matched = true
          rescue ValidationError
            item_matched = false
          end

          if options[:record_errors]
            diff = validation_errors(processor).count - pre_validation_error_count
            item_matched = false if diff.positive?
          end

          if item_matched
            matched = true
          elsif options[:record_errors]
            diff = validation_errors(processor).count - pre_validation_error_count
            if retained < MAX_RETAINED_ITEM_ERRORS
              item_errors["contains item ##{index}"] = []
              while diff.positive?
                diff -= 1
                item_errors["contains item ##{index}"].unshift(validation_errors(processor).pop)
              end
              retained += 1
            else
              while diff.positive?
                diff -= 1
                validation_errors(processor).pop
              end
            end
          end
        end

        return if matched

        message = "The property '#{build_fragment(fragments)}' of type array did not contain any items matching the given schema"
        validation_error(processor, message, fragments, current_schema, self, options[:record_errors])
        validation_errors(processor).last.sub_errors = item_errors if options[:record_errors]
      end
    end
  end
end
