require 'json-schema/validators/draft6'

module JSON
  class Schema
    class Draft7 < Draft6
      def initialize
        super
        @attributes = @attributes.merge(
          'if' => JSON::Schema::IfThenElseAttribute,
          'then' => JSON::Schema::NoOpAttribute,
          'else' => JSON::Schema::NoOpAttribute,
          'contains' => JSON::Schema::ContainsAttribute,
        )
        @uri = JSON::Util::URI.parse('http://json-schema.org/draft-07/schema#')
        @names = ['draft7', 'http://json-schema.org/draft-07/schema#']
        @metaschema_name = 'draft-07.json'
      end

      # Draft 7 is registered as a separate, selectable dialect. The default
      # dialect is intentionally left unchanged (Draft 6).
      JSON::Validator.register_validator(new)
    end
  end
end
