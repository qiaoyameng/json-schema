require 'json-schema/attributes/limits/properties'

module JSON
  class Schema
    class MaxPropertiesAttribute < PropertiesLimitAttribute
      def self.limit_name
        'maxProperties'
      end

      def self.error_message(_schema, limit = limit(schema))
        "had more properties than the allowed #{limit}"
      end
    end
  end
end
