require File.expand_path('support/test_helper', __dir__)
require 'thread' # rubocop:disable Lint/RedundantRequireStatement

class ValidationContextTest < Minitest::Test
  COMMON_URI = 'http://tenant.example/common.json#'.freeze
  DETAIL_URI = 'http://tenant.example/detail.json#'.freeze

  class RecordingReader < JSON::Schema::Reader
    attr_reader :calls

    def initialize(definition, calls)
      super(accept_uri: true, accept_file: false)
      @definition = definition
      @calls = calls
    end

    def read(uri)
      @calls << uri.to_s
      JSON::Schema.new(@definition.fetch(uri.to_s), JSON::Util::URI.parse(uri.to_s))
    end
  end

  class FailingOnceReader < JSON::Schema::Reader
    def initialize(calls)
      super(accept_uri: true, accept_file: false)
      @mutex = Mutex.new
      @calls = calls
    end

    def read(uri)
      @mutex.synchronize { @calls << uri.to_s }
      raise JSON::Schema::ReadFailed.new(uri.to_s, :uri)
    end
  end

  class SingleSchemaReader < JSON::Schema::Reader
    attr_reader :calls

    def initialize(definition)
      super(accept_uri: true, accept_file: false)
      @definition = definition
      @calls = []
    end

    def read(uri)
      @calls << uri.to_s
      JSON::Schema.new(@definition, JSON::Util::URI.parse(uri.to_s))
    end
  end

  class MetaschemaReader < JSON::Schema::Reader
    attr_reader :calls

    def initialize
      super(accept_uri: true, accept_file: true)
      @calls = []
    end

    def read(uri)
      @calls << uri.to_s
      super
    end
  end

  def teardown
    JSON::Validator.clear_cache
  end

  def test_identical_uri_and_format_use_context_rules
    calls_a = Queue.new
    calls_b = Queue.new
    trap = JSON::Schema.new({ 'type' => 'integer' }, JSON::Util::URI.parse(DETAIL_URI))
    JSON::Validator.add_schema(trap)

    context_a = context('tenant', calls_a) do |value|
      raise JSON::Schema::CustomFormatError, 'wrong tenant' unless value == 'accepted-a'
    end
    context_b = context('tenant', calls_b) do |value|
      raise JSON::Schema::CustomFormatError, 'wrong tenant' unless value == 'accepted-b'
    end
    schema = { '$ref' => COMMON_URI }

    assert JSON::Validator.validate(schema, 'accepted-a', validation_context: context_a, clear_cache: false)
    assert JSON::Validator.validate(schema, 'accepted-b', validation_context: context_b, clear_cache: false)
    refute JSON::Validator.validate(schema, 'accepted-b', validation_context: context_a, clear_cache: false)
    refute JSON::Validator.validate(schema, 'accepted-a', validation_context: context_b, clear_cache: false)

    assert_equal [COMMON_URI, DETAIL_URI], drain(calls_a)
    assert_equal [COMMON_URI, DETAIL_URI], drain(calls_b)
    assert context_a.schema_loaded?(COMMON_URI)
    refute JSON::Validator.schema_loaded?(COMMON_URI)
  end

  def test_derived_context_replaces_schema_without_changing_parent
    old_reader = SingleSchemaReader.new({ 'type' => 'string' })
    new_reader = SingleSchemaReader.new({ 'type' => 'integer' })
    parent = JSON::Validator::ValidationContext.new(schema_reader: old_reader)
    schema = { '$ref' => COMMON_URI }

    JSON::Validator.validate!(schema, 'old', validation_context: parent, clear_cache: false)
    child = parent.derive(schema_reader: new_reader)
    child.replace_schema(JSON::Schema.new(
                           { 'type' => 'integer' },
                           JSON::Util::URI.parse(COMMON_URI),
                         ))

    assert JSON::Validator.validate!(schema, 42, validation_context: child, clear_cache: false)
    assert JSON::Validator.validate!(schema, 'still old', validation_context: parent, clear_cache: false)
    assert_equal [COMMON_URI], old_reader.calls
    assert_equal [], new_reader.calls
  end

  def test_clear_cache_only_affects_named_context
    calls_a = []
    calls_b = []
    context_a = context('tenant', calls_a) do |value|
      raise JSON::Schema::CustomFormatError, 'wrong tenant' unless value == 'accepted-a'
    end
    context_b = context('tenant', calls_b) do |value|
      raise JSON::Schema::CustomFormatError, 'wrong tenant' unless value == 'accepted-b'
    end
    schema = { '$ref' => COMMON_URI }

    JSON::Validator.validate!(schema, 'accepted-a', validation_context: context_a, clear_cache: false)
    JSON::Validator.validate!(schema, 'accepted-b', validation_context: context_b, clear_cache: false)

    context_a.clear_cache
    JSON::Validator.validate!(schema, 'accepted-a', validation_context: context_a, clear_cache: false)
    JSON::Validator.validate!(schema, 'accepted-b', validation_context: context_b, clear_cache: false)

    assert_equal [COMMON_URI, DETAIL_URI, COMMON_URI, DETAIL_URI], calls_a
    assert_equal [COMMON_URI, DETAIL_URI], calls_b
  end

  def test_clear_cache_does_not_mutate_validator_snapshot
    reader = SingleSchemaReader.new({ 'type' => 'string' })
    parent = JSON::Validator::ValidationContext.new(schema_reader: reader)
    schema = { '$ref' => COMMON_URI }

    JSON::Validator.validate!(schema, 'old', validation_context: parent, clear_cache: false)
    snapshot = parent.snapshot

    JSON::Validator.validate!(schema, 'still old', validation_context: snapshot, clear_cache: true)

    assert snapshot.schema_loaded?(COMMON_URI)
  end

  def test_failed_resource_load_does_not_publish_schema
    calls = Queue.new
    context = JSON::Validator::ValidationContext.new(schema_reader: FailingOnceReader.new(calls))

    assert_raises(JSON::Schema::ReadFailed) do
      JSON::Validator.validate!({ '$ref' => COMMON_URI }, 'anything', validation_context: context)
    end

    refute context.schema_loaded?(COMMON_URI)
    assert_equal [COMMON_URI], drain(calls)
  end

  def test_meta_schema_validation_uses_context_reader
    reader = MetaschemaReader.new
    context = JSON::Validator::ValidationContext.new(schema_reader: reader)
    schema = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'type' => 'string',
    }

    assert JSON::Validator.validate(
      schema,
      'value',
      validation_context: context,
      validate_schema: true,
      clear_cache: false,
    )
    assert_equal 1, reader.calls.size
    assert reader.calls.first.end_with?('resources/draft-04.json')
    refute(JSON::Validator.schemas.values.any? { |cached_schema| cached_schema.uri.to_s.end_with?('draft-04.json') })
  end

  def test_validation_keeps_complete_snapshot_when_registration_changes
    started = Queue.new
    release = Queue.new
    calls = Queue.new
    reader = Class.new(JSON::Schema::Reader) do
      define_method(:initialize) do |started, release, calls|
        super(accept_uri: true, accept_file: false)
        @started = started
        @release = release
        @calls = calls
      end

      define_method(:read) do |uri|
        @started << uri.to_s
        @release.pop
        @calls << uri.to_s
        JSON::Schema.new({ 'type' => 'string', 'format' => 'tenant' }, JSON::Util::URI.parse(uri.to_s))
      end
    end.new(started, release, calls)

    context = JSON::Validator::ValidationContext.new(schema_reader: reader)
    context.register_format_validator('tenant', lambda { |value|
      raise JSON::Schema::CustomFormatError, 'wrong version' unless value == 'first'
    }, [nil])
    result = nil

    thread = Thread.new do
      result = JSON::Validator.validate(
        { '$ref' => COMMON_URI },
        'first',
        validation_context: context,
        clear_cache: false,
      )
    end

    assert_equal COMMON_URI, started.pop
    context.register_format_validator('tenant', lambda { |value|
      raise JSON::Schema::CustomFormatError, 'wrong version' unless value == 'second'
    }, [nil])
    release << true
    thread.join

    assert result
    assert JSON::Validator.validate(
      { '$ref' => COMMON_URI },
      'second',
      validation_context: context,
      clear_cache: false,
    )
  end

  private

  def context(format_name, calls, &block)
    definition = {
      COMMON_URI => {
        '$schema' => 'http://json-schema.org/draft-04/schema#',
        'allOf' => [{ '$ref' => DETAIL_URI }],
      },
      DETAIL_URI => {
        '$schema' => 'http://json-schema.org/draft-04/schema#',
        'type' => 'string',
        'format' => format_name,
      },
    }
    context = JSON::Validator::ValidationContext.new(
      schema_reader: RecordingReader.new(definition, calls),
    )
    context.register_format_validator(format_name, block, ['draft4'])
    context
  end

  def drain(queue)
    values = []
    values << queue.pop(true) while values.size < 100
  rescue ThreadError
    values
  end
end
