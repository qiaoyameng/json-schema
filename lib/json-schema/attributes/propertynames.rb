require 'json-schema/attribute'

module JSON
  class Schema
    class PropertyNames < Attribute
      def self.validate(current_schema, data, fragments, processor, validator, options = {})
        return unless data.is_a?(Hash)

        propnames = current_schema.schema['propertyNames']
        return if propnames.nil?

        schema = JSON::Schema.new(propnames, current_schema.uri, validator)
        data.each_key do |key|
          schema.validate(key, fragments + [key], processor, options)
        end
      end
    end
  end
end
