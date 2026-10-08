require 'json-schema/attribute'

module JSON
  class Schema
    class PatternPropertiesAttribute < Attribute
      def self.validate(current_schema, data, fragments, processor, validator, options = {})
        return unless data.is_a?(Hash)

        current_schema.schema['patternProperties'].each do |property, property_schema|
          regexp = if options[:portable_pattern]
                     JSON::Util::PortablePattern.compile(property)
                   else
                     Regexp.new(property)
                   end

          # Check each key in the data hash to see if it matches the regex
          data.each do |key, _value|
            next unless regexp.match(key)

            schema = JSON::Schema.new(property_schema, current_schema.uri, validator)
            schema.validate(data[key], fragments + [key], processor, options)
          end
        end
      end
    end
  end
end
