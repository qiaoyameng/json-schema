require 'json-schema/attributes/limits/length'

module JSON
  class Schema
    class MaxLengthAttribute < LengthLimitAttribute
      def self.limit_name
        'maxLength'
      end

      def self.error_message(_schema, limit = limit(schema))
        "was not of a maximum string length of #{limit}"
      end
    end
  end
end
