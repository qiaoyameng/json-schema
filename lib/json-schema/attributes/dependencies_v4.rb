require 'json-schema/attributes/dependencies'

module JSON
  class Schema
    class DependenciesV4Attribute < DependenciesAttribute
      def self.accept_value?(value)
        value.is_a?(Array) || value.is_a?(Hash) || value == true || value == false
      end
    end
  end
end
