require File.expand_path('support/test_helper', __dir__)

class ValidationContextTest < Minitest::Test
  COMMON_URI = 'http://tenant.example.com/common.json'.freeze
  LEAF_URI = 'http://tenant.example.com/leaf.json'.freeze

  # Records every read and serves tenant specific schema bodies. Unknown
  # remote URIs fail; file locations (e.g. meta-schemas) fall back to the
  # default reader behavior.
  class RecordingReader < JSON::Schema::Reader
    attr_reader :calls

    def initialize(bodies = {})
      super()
      @bodies = bodies
      @calls = []
      @calls_mutex = Mutex.new
    end

    def read(location)
      key = location.to_s.delete_suffix('#')
      @calls_mutex.synchronize { @calls << key }
      body = @bodies[key]
      return JSON::Schema.new(body, Addressable::URI.parse(location.to_s)) if body

      scheme = JSON::Util::URI.parse(key).scheme
      return super if scheme.nil? || scheme == 'file'

      raise JSON::Schema::ReadFailed.new(location.to_s, :uri)
    end
  end

  def setup
    JSON::Validator.clear_cache
    @original_reader = JSON::Validator.schema_reader
  end

  def teardown
    JSON::Validator.schema_reader = @original_reader
    JSON::Validator.clear_cache
  end

  def build_tenant(inline_limit, leaf_pattern, expected_value)
    reader = RecordingReader.new(
      COMMON_URI => {
        'id' => COMMON_URI,
        'type' => 'string',
        'format' => 'parity',
        'allOf' => [{ '$ref' => LEAF_URI }],
      }.merge(inline_limit),
      LEAF_URI => {
        'id' => LEAF_URI,
        'pattern' => leaf_pattern,
      },
    )
    context = JSON::ValidationContext.new(schema_reader: reader)
    context.register_format_validator('parity', lambda { |value|
      raise JSON::Schema::CustomFormatError, "must be #{expected_value}" unless value == expected_value
    })
    [context, reader]
  end

  def validation_errors_for(context, data)
    JSON::Validator.fully_validate({ '$ref' => COMMON_URI }, data, validation_context: context, clear_cache: false)
  end

  def test_interleaved_tenants_with_same_uri_and_format_name_do_not_collide
    context_a, reader_a = build_tenant({ 'minLength' => 2 }, '^a', 'aa')
    context_b, reader_b = build_tenant({ 'maxLength' => 1 }, '^b', 'b')

    # Interleave validations of both tenants: same schema URI, same custom
    # format name, opposite rules.
    2.times do
      assert_empty(validation_errors_for(context_a, 'aa'), 'tenant A accepts its own value')
      assert_empty(validation_errors_for(context_b, 'b'), 'tenant B accepts its own value')
      refute_empty(validation_errors_for(context_a, 'b'), 'tenant A rejects tenant B value')
      refute_empty(validation_errors_for(context_b, 'aa'), 'tenant B rejects tenant A value')
    end

    # Each tenant read exactly its own copy of each schema, once: the second
    # round of validations hit the tenant's own context cache, and no
    # cross-tenant cache hit served the other tenant's definitions.
    assert_equal([COMMON_URI, LEAF_URI].sort, reader_a.calls.uniq.sort)
    assert_equal([COMMON_URI, LEAF_URI].sort, reader_b.calls.uniq.sort)
    reader_a.calls.each do |uri|
      assert_equal(1, reader_a.calls.count(uri), "tenant A read #{uri} exactly once")
      assert_equal(1, reader_b.calls.count(uri), "tenant B read #{uri} exactly once")
    end

    # Nothing leaked into the class-level default registry.
    refute JSON::Validator.schema_loaded?(COMMON_URI)
    refute JSON::Validator.schema_loaded?(LEAF_URI)
  end

  def test_nested_ref_and_schema_validation_stay_within_the_context
    context, reader = build_tenant({ 'minLength' => 2 }, '^a', 'aa')

    errors = JSON::Validator.fully_validate({ '$ref' => COMMON_URI }, 'aa',
                                            validation_context: context,
                                            validate_schema: true,
                                            clear_cache: false)

    assert_empty errors
    # The nested $ref target and the meta-schema were registered on the
    # given context, not on the class-level registry.
    assert context.schema_loaded?(COMMON_URI)
    assert context.schema_loaded?(LEAF_URI)
    refute JSON::Validator.schema_loaded?(COMMON_URI)
    refute JSON::Validator.schema_loaded?(LEAF_URI)
    assert_includes reader.calls, COMMON_URI
    assert_includes reader.calls, LEAF_URI
  end

  def test_derived_context_overrides_do_not_modify_parent
    parent, = build_tenant({ 'minLength' => 2 }, '^a', 'aa')
    child = parent.derive
    child.register_format_validator('parity', lambda { |value|
      raise JSON::Schema::CustomFormatError, 'must be b' unless value == 'b'
    })
    child.add_schema(JSON::Schema.new({ 'type' => 'integer' }, Addressable::URI.parse('http://tenant.example.com/child-only.json')))

    schema = { 'type' => 'string', 'format' => 'parity' }

    assert JSON::Validator.validate(schema, 'aa', validation_context: parent)
    refute JSON::Validator.validate(schema, 'b', validation_context: parent)
    assert JSON::Validator.validate(schema, 'b', validation_context: child)
    refute JSON::Validator.validate(schema, 'aa', validation_context: child)

    assert child.schema_loaded?('http://tenant.example.com/child-only.json')
    refute parent.schema_loaded?('http://tenant.example.com/child-only.json')
  end

  def test_clear_cache_only_affects_the_target_context
    context_a, = build_tenant({ 'minLength' => 2 }, '^a', 'aa')
    context_b, = build_tenant({ 'maxLength' => 1 }, '^b', 'b')

    assert_empty validation_errors_for(context_a, 'aa')
    assert_empty validation_errors_for(context_b, 'b')
    assert context_a.schema_loaded?(COMMON_URI)
    assert context_b.schema_loaded?(COMMON_URI)

    context_a.clear_cache

    refute context_a.schema_loaded?(COMMON_URI)
    assert context_b.schema_loaded?(COMMON_URI)

    # The :clear_cache validation option clears the bound context only.
    JSON::Validator.validate({ '$ref' => COMMON_URI }, 'b', validation_context: context_b, clear_cache: true)

    refute context_b.schema_loaded?(COMMON_URI)

    # The class-level clear_cache only clears the default context.
    JSON::Validator.add_schema(JSON::Schema.new({ 'type' => 'string' }, Addressable::URI.parse('http://tenant.example.com/default.json')))
    context_b.add_schema(JSON::Schema.new({ 'type' => 'string' }, Addressable::URI.parse('http://tenant.example.com/default.json')))

    JSON::Validator.clear_cache

    refute JSON::Validator.schema_loaded?('http://tenant.example.com/default.json')
    assert context_b.schema_loaded?('http://tenant.example.com/default.json')
  end

  def test_validator_uses_the_context_snapshot_taken_at_construction
    context, = build_tenant({ 'minLength' => 2 }, '^a', 'aa')
    schema = { 'type' => 'string', 'format' => 'parity' }
    validator = JSON::Validator.new(schema, validation_context: context)

    # Registering a conflicting rule on the context afterwards must not
    # affect the already constructed validator.
    context.register_format_validator('parity', lambda { |value|
      raise JSON::Schema::CustomFormatError, 'must be b' unless value == 'b'
    })

    assert validator.validate('aa')
    assert_raises(JSON::Schema::ValidationError) { validator.validate('b') }

    # Fresh validators see the new rule.
    assert JSON::Validator.validate(schema, 'b', validation_context: context)
  end

  def test_concurrent_registration_keeps_single_validation_consistent
    started = Queue.new
    release = Queue.new
    reader = RecordingReader.new(COMMON_URI => { 'id' => COMMON_URI, 'type' => 'string' })
    gate = reader.method(:read)
    reader.define_singleton_method(:read) do |location|
      started << true
      release.pop
      gate.call(location)
    end
    context = JSON::ValidationContext.new(schema_reader: reader)

    validator = nil
    thread = Thread.new do
      validator = JSON::Validator.new({ '$ref' => COMMON_URI }, validation_context: context)
    end

    started.pop
    # Another thread registers a new, conflicting version while the first
    # validation is still being assembled.
    context.clear_cache
    context.add_schema(JSON::Schema.new({ 'type' => 'integer' }, Addressable::URI.parse(COMMON_URI)))
    release << true
    thread.join

    # The in-flight validation sees exactly one complete version (string).
    assert validator.validate('hello')
    assert_raises(JSON::Schema::ValidationError) { validator.validate(1) }

    # New validators see the newly registered version.
    assert JSON::Validator.validate({ '$ref' => COMMON_URI }, 1, validation_context: context)
  end

  def test_failed_resource_load_does_not_publish_half_a_schema
    main_uri = 'http://tenant.example.com/main.json'
    missing_uri = 'http://tenant.example.com/missing.json'
    reader = RecordingReader.new(main_uri => { 'id' => main_uri, '$ref' => missing_uri })
    context = JSON::ValidationContext.new(schema_reader: reader)

    assert_raises(JSON::Schema::ReadFailed) do
      JSON::Validator.new({ '$ref' => main_uri }, validation_context: context)
    end

    refute context.schema_loaded?(main_uri)
    refute context.schema_loaded?(missing_uri)
  end

  def test_class_level_api_uses_the_default_context
    reader = RecordingReader.new(COMMON_URI => { 'id' => COMMON_URI, 'type' => 'string' })
    JSON::Validator.schema_reader = reader

    assert_same reader, JSON::Validator.default_context.schema_reader
    assert JSON::Validator.validate({ '$ref' => COMMON_URI }, 'hello', clear_cache: false)
    assert JSON::Validator.schema_loaded?(COMMON_URI)

    JSON::Validator.clear_cache

    refute JSON::Validator.schema_loaded?(COMMON_URI)
  end
end
