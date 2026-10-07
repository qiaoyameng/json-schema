require 'json-schema/attributes/limits/properties'

module JSON
  class Schema
    class MinPropertiesAttribute < PropertiesLimitAttribute
      def self.limit_name
        'minProperties'
      end

      def self.error_message(_schema, limit = limit(schema))
        "did not contain a minimum number of properties #{limit}"
      end
    end
  end
end
