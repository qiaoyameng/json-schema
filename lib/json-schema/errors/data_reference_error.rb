require 'json-schema/errors/validation_error'

module JSON
  class Schema
    class DataReferenceError < ValidationError
      attr_accessor :data_pointer

      def initialize(message, fragments, failed_attribute, schema, data_pointer, properties = [])
        @data_pointer = data_pointer
        super(message, fragments, failed_attribute, schema, properties)
      end

      def to_hash
        base = super
        base[:data_pointer] = @data_pointer
        base
      end
    end
  end
end
