require 'json-schema/attributes/limits/items'

module JSON
  class Schema
    class MaxItemsAttribute < ItemsLimitAttribute
      def self.limit_name
        'maxItems'
      end

      def self.error_message(_schema, limit = limit(schema))
        "had more items than the allowed #{limit}"
      end
    end
  end
end
