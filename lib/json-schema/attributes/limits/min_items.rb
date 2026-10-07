require 'json-schema/attributes/limits/items'

module JSON
  class Schema
    class MinItemsAttribute < ItemsLimitAttribute
      def self.limit_name
        'minItems'
      end

      def self.error_message(_schema, limit = limit(schema))
        "did not contain a minimum number of items #{limit}"
      end
    end
  end
end
