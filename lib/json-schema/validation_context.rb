require 'json-schema/schema/reader'
require 'json-schema/util/uri'

module JSON
  # A ValidationContext bundles the mutable state a validation run depends
  # on: the schema registry, the custom format rules and the schema reader.
  #
  # Contexts are isolated from each other: two contexts may register
  # different schemas under the same URI, or conflicting format rules under
  # the same name, without interfering. This allows several tenants to
  # share one process safely.
  #
  # A context can be derived into a child context via #derive. The child
  # starts with a copy of the parent's registry and format rules; replacing
  # definitions on the child never modifies the parent.
  class ValidationContext
    attr_accessor :schema_reader
    attr_reader :schemas

    def initialize(schema_reader: nil)
      @schema_reader = schema_reader || JSON::Schema::Reader.new
      @schemas = {}
      @formats = {}
      @mutex = Mutex.new
    end

    # @return [ValidationContext] a child context holding a snapshot of this
    #   context's schema registry and format rules. Modifications of the
    #   child do not leak back into the parent.
    def derive
      child = self.class.new(schema_reader: schema_reader)
      @mutex.synchronize do
        child.instance_variable_set(:@schemas, @schemas.dup)
        child.instance_variable_set(:@formats, @formats.transform_values(&:dup))
      end
      child
    end

    # Atomically publishes the schemas registered on a derived context into
    # this context. Schemas already registered here are kept. Either all
    # incoming schemas become visible at once or none do, so concurrent
    # readers never observe a partially published schema set.
    def absorb!(other)
      incoming = other.schemas
      @mutex.synchronize do
        incoming.each do |key, schema|
          @schemas[key] ||= schema
        end
      end
      self
    end

    # Clears this context's schema registry only.
    def clear_cache
      @mutex.synchronize { @schemas = {} }
    end

    def add_schema(schema)
      key = schema_key_for(schema.uri)
      @mutex.synchronize { @schemas[key] ||= schema }
    end

    def schema_for_uri(uri)
      # We only store normalized uris terminated with fragment #, so we can
      # try whether normalization can be skipped
      @schemas[uri] || @schemas[schema_key_for(uri)]
    end

    def schema_loaded?(schema_uri)
      !schema_for_uri(schema_uri).nil?
    end

    def schema_key_for(uri)
      key = Util::URI.normalized_uri(uri).to_s
      key.end_with?('#') ? key : "#{key}#"
    end

    # Registers a custom format rule on this context only. The rule shadows
    # any format with the same name registered on the schema validators.
    def register_format_validator(format, validation_proc, versions = all_format_versions)
      custom_format_validator = JSON::Schema::CustomFormat.new(validation_proc)
      validators_for(versions).each do |validator|
        format_overrides_for(validator)[format.to_s] = custom_format_validator
      end
    end

    # Removes this context's custom rule for +format+, falling back to the
    # formats registered on the schema validators again.
    def deregister_format_validator(format, versions = all_format_versions)
      validators_for(versions).each do |validator|
        overrides = @mutex.synchronize { @formats[validator] }
        overrides&.delete(format.to_s)
      end
    end

    # Removes all custom format rules held by this context.
    def restore_default_formats(versions = all_format_versions)
      validators_for(versions).each do |validator|
        @mutex.synchronize { @formats.delete(validator) }
      end
    end

    # Looks up the format rule for +format+ in this context, falling back
    # to the rules registered on the schema validator itself.
    def format_for(validator, format)
      overrides = @formats[validator]
      (overrides && overrides[format.to_s]) || validator.formats[format.to_s]
    end

    private

    def all_format_versions
      JSON::Validator.validators.flat_map { |_k, v| v.names.first } + [nil]
    end

    def validators_for(versions)
      Array(versions).map { |version| JSON::Validator.validator_for_name(version) }
    end

    def format_overrides_for(validator)
      @mutex.synchronize { @formats[validator] ||= {} }
    end
  end
end
