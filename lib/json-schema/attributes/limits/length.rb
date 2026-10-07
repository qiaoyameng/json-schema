require 'json-schema/attributes/limit'

module JSON
  class Schema
    class LengthLimitAttribute < LimitAttribute
      def self.acceptable_type
        String
      end

      def self.value(data)
        data.length
      end

      def self.invalid_referenced_limit(referenced)
        return 'is not an integer' unless referenced.is_a?(Integer)
        return 'is a negative length' if referenced.negative?

        nil
      end
    end
  end
end
