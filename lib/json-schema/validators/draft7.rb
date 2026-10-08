require 'json-schema/schema/validator'

module JSON
  class Schema
    class Draft7 < Validator
      def initialize
        super
        @attributes = {
          'type' => JSON::Schema::TypeV4Attribute,
          'allOf' => JSON::Schema::AllOfAttribute,
          'anyOf' => JSON::Schema::AnyOfAttribute,
          'oneOf' => JSON::Schema::OneOfAttribute,
          'not' => JSON::Schema::NotAttribute,
          'disallow' => JSON::Schema::DisallowAttribute,
          'format' => JSON::Schema::FormatAttribute,
          'maximum' => JSON::Schema::MaximumAttribute,
          'minimum' => JSON::Schema::MinimumAttribute,
          'exclusiveMaximum' => JSON::Schema::ExclusiveMaximumAttribute,
          'exclusiveMinimum' => JSON::Schema::ExclusiveMinimumAttribute,
          'minItems' => JSON::Schema::MinItemsAttribute,
          'maxItems' => JSON::Schema::MaxItemsAttribute,
          'minProperties' => JSON::Schema::MinPropertiesAttribute,
          'maxProperties' => JSON::Schema::MaxPropertiesAttribute,
          'uniqueItems' => JSON::Schema::UniqueItemsAttribute,
          'minLength' => JSON::Schema::MinLengthAttribute,
          'maxLength' => JSON::Schema::MaxLengthAttribute,
          'multipleOf' => JSON::Schema::MultipleOfAttribute,
          'enum' => JSON::Schema::EnumAttribute,
          'properties' => JSON::Schema::PropertiesV4Attribute,
          'required' => JSON::Schema::RequiredAttribute,
          'pattern' => JSON::Schema::PatternAttribute,
          'patternProperties' => JSON::Schema::PatternPropertiesAttribute,
          'additionalProperties' => JSON::Schema::AdditionalPropertiesAttribute,
          'items' => JSON::Schema::ItemsAttribute,
          'additionalItems' => JSON::Schema::AdditionalItemsAttribute,
          'dependencies' => JSON::Schema::DependenciesV4Attribute,
          'extends' => JSON::Schema::ExtendsAttribute,
          'const' => JSON::Schema::ConstAttribute,
          'contains' => JSON::Schema::ContainsAttribute,
          'if' => JSON::Schema::IfThenElseAttribute,
          '$ref' => JSON::Schema::RefAttribute,
          'propertyNames' => JSON::Schema::PropertyNames,
        }
        @default_formats = {
          'date' => DateFormat,
          'time' => TimeFormat,
          'date-time' => DateTimeV4Format,
          'ipv4' => IP4Format,
          'ipv6' => IP6Format,
          'uri' => UriFormat,
        }
        @formats = @default_formats.clone
        @uri = JSON::Util::URI.parse('http://json-schema.org/draft-07/schema#')
        @names = ['draft7', 'http://json-schema.org/draft-07/schema#']
        @metaschema_name = 'draft-07.json'
      end

      # Draft 7 is registered as an opt-in validator only; the default
      # validator remains unchanged.
      JSON::Validator.register_validator(new)
    end
  end
end
