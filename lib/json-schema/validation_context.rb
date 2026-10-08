require 'json-schema/attributes/formats/custom'
require 'set'

module JSON
  class Validator
    class ValidationContext
      attr_reader :schemas, :formats
      attr_accessor :schema_reader

      def initialize(schemas: nil, formats: nil, schema_reader: nil, delegate_formats: false, added_keys: nil, snapshot: false)
        @mutex = Mutex.new
        @schemas = schemas || {}
        @formats = formats || {}
        @schema_reader = schema_reader
        @delegate_formats = delegate_formats
        @added_keys = added_keys ? Set.new(added_keys) : Set.new
        @snapshot = snapshot
      end

      def self.default
        new(schema_reader: JSON::Schema::Reader.new, delegate_formats: true)
      end

      def derive(schemas: :unset, formats: :unset, schema_reader: :unset)
        @mutex.synchronize do
          self.class.new(
            schemas: copy_schemas((schemas == :unset) ? @schemas : schemas),
            formats: copy_formats_from((formats == :unset) ? @formats : formats),
            schema_reader: (schema_reader == :unset) ? @schema_reader : schema_reader,
          )
        end
      end

      def snapshot(schema_reader = nil)
        @mutex.synchronize do
          self.class.new(
            schemas: copy_schemas(@schemas),
            formats: @delegate_formats ? current_formats : copy_formats,
            schema_reader: schema_reader || @schema_reader || JSON::Schema::Reader.new,
            added_keys: Set.new,
            snapshot: true,
          )
        end
      end

      def commit(other_context)
        other_context.synchronize do
          @mutex.synchronize do
            @added_keys.each do |key|
              next unless @schemas.key?(key)
              next if other_context.schemas.key?(key)

              other_context.schemas[key] = snapshot_schema_for(@schemas.fetch(key), other_context)
            end
            other_context.added_keys.merge(@added_keys)
          end
        end
      end

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def snapshot?
        @snapshot
      end

      def schema_key_for(uri)
        key = JSON::Util::URI.normalized_uri(uri).to_s
        key.end_with?('#') ? key : "#{key}#"
      end

      def add_schema(schema)
        key = schema_key_for(schema.uri)

        @mutex.synchronize do
          existing = @schemas[key]
          unless existing
            @schemas[key] = schema
            @added_keys.add(key)
          end
          existing || schema
        end
      end

      def replace_schema(schema)
        @mutex.synchronize { @schemas[schema_key_for(schema.uri)] = schema }
      end

      def schema_for_uri(uri)
        @mutex.synchronize do
          @schemas[uri] ||
            begin
              key = schema_key_for(uri)
              @schemas[key] unless key == uri
            end
        end
      end

      def schema_loaded?(uri)
        !schema_for_uri(uri).nil?
      end

      def clear_cache
        @mutex.synchronize { @schemas = {} } unless @snapshot
      end

      def register_format_validator(format, validation_proc, versions = nil)
        format_name = format.to_s
        versions = format_versions if versions.nil?

        @mutex.synchronize do
          versions.each do |version|
            validator = JSON::Validator.validator_for_name(version)
            formats_for(validator)[format_name] = JSON::Schema::CustomFormat.new(validation_proc)
          end
        end
      end

      def deregister_format_validator(format, versions = nil)
        format_name = format.to_s
        validators = validators_for(versions)

        @mutex.synchronize do
          validators.each do |validator|
            default_format = validator.default_formats[format_name]
            if default_format
              formats_for(validator)[format_name] = default_format
            else
              formats_for(validator).delete(format_name)
            end
          end
        end
      end

      def restore_default_formats(versions = nil)
        validators = validators_for(versions)

        @mutex.synchronize do
          validators.each do |validator|
            if @delegate_formats
              validator.formats.replace(validator.default_formats.clone)
            else
              @formats[format_key(validator)] = validator.default_formats.clone
            end
          end
        end
      end

      def format_for(validator, format)
        @mutex.synchronize do
          if @delegate_formats
            validator.formats[format.to_s]
          else
            @formats.dig(format_key(validator), format.to_s)
          end
        end
      end

      def copy_schema(schema)
        JSON::Schema.new(
          Marshal.load(Marshal.dump(schema.schema)),
          Marshal.load(Marshal.dump(schema.uri)),
          schema.validator,
        )
      end

      def snapshot_schema_for(schema, other_context)
        other_context.delegate_formats? ? schema : copy_schema(schema)
      end

      protected

      attr_reader :added_keys

      def delegate_formats?
        @delegate_formats
      end

      private

      def copy_schemas(schemas)
        schemas.transform_values { |schema| copy_schema(schema) }
      end

      def copy_formats
        copy_formats_from(@formats)
      end

      def copy_formats_from(formats)
        formats.each_with_object({}) do |(key, value), result|
          result[key] = value.clone
        end
      end

      def current_formats
        [JSON::Validator.validator_for_name(nil), *JSON::Validator.validators.values].uniq.to_h do |validator|
          [format_key(validator), validator.formats.clone]
        end
      end

      def format_versions
        [*JSON::Validator.validators.values.map(&:names).flatten, nil]
      end

      def validators_for(versions)
        if versions.nil?
          [JSON::Validator.validator_for_name(nil), *JSON::Validator.validators.values].uniq
        else
          versions.map do |version|
            version.respond_to?(:formats) ? version : JSON::Validator.validator_for_name(version)
          end
        end
      end

      def format_key(validator)
        (validator == JSON::Validator.validator_for_name(nil)) ? '__default__' : JSON::Validator.schema_key_for(validator.uri)
      end

      def formats_for(validator)
        if @delegate_formats
          validator.formats
        else
          @formats[format_key(validator)] ||= validator.default_formats.clone
        end
      end
    end
  end
end
