require 'json-schema/attributes/limits/numeric'

module JSON
  class Schema
    class ExclusiveMaximumAttribute < NumericLimitAttribute
      def self.limit_name
        'exclusiveMaximum'
      end

      def self.exclusive?(_schema)
        true
      end

      def self.invalid?(schema, data)
        data >= limit(schema)
      end

      def self.error_message(schema)
        format('did not have a value less than %s', limit(schema))
      end
    end
  end
end
