require File.expand_path('support/test_helper', __dir__)

class DataReferenceTest < Minitest::Test
  OPTIONS = { clear_cache: true, validate_schema: false, '$data' => true }.freeze

  def objects(schema, data)
    JSON::Validator.fully_validate(schema, data, OPTIONS.merge(errors_as_objects: true))
  end

  def strings(schema, data, options = OPTIONS)
    JSON::Validator.fully_validate(schema, data, options)
  end

  def test_max_items_taken_from_limit_property
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer' },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }

    assert_valid(schema, { 'limit' => 3, 'items' => [1, 2, 3] }, OPTIONS)
    refute_valid(schema, { 'limit' => 2, 'items' => [1, 2, 3] }, OPTIONS)
  end

  def test_maximum_minimum_and_maxlength
    schema = {
      'type' => 'object',
      'properties' => {
        'hi' => { 'type' => 'number' },
        'lo' => { 'type' => 'number' },
        'value' => {
          'type' => 'number',
          'maximum' => { '$data' => '/hi' },
          'minimum' => { '$data' => '/lo' },
        },
        'name' => { 'type' => 'string', 'maxLength' => { '$data' => '/hi' } },
      },
    }

    assert_valid(schema, { 'hi' => 10, 'lo' => 0, 'value' => 10, 'name' => 'abcdefghij' }, OPTIONS)
    errors = strings(schema, { 'hi' => 2, 'lo' => 1, 'value' => 3, 'name' => 'xyz' })

    assert_equal(2, errors.size)
    assert_match(/maximum/, errors[0])
    assert_match(/max(?:imum)? string length/, errors[1])
  end

  def test_missing_reference_is_a_distinct_error_carrying_both_paths
    schema = {
      'type' => 'object',
      'properties' => {
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/missing/limit' } },
      },
    }

    errors = objects(schema, { 'items' => [1] })

    assert_equal(1, errors.size)
    assert_equal('MaxItems', errors.first[:failed_attribute])
    assert_equal('#/items', errors.first[:fragment])
    assert_equal('/missing/limit', errors.first[:data_pointer])
    assert_match(/does not exist/, errors.first[:message])
  end

  def test_null_reference
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => {},
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }

    errors = objects(schema, { 'limit' => nil, 'items' => [1] })
    data_errors = errors.select { |e| e[:data_pointer] == '/limit' }

    assert_equal(1, data_errors.size)
    assert_match(/references null/, data_errors.first[:message])
  end

  def test_invalid_type_reference
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => {},
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }

    errors = objects(schema, { 'limit' => 'two', 'items' => [] })
    data_errors = errors.select { |e| e[:data_pointer] == '/limit' }

    assert_equal(1, data_errors.size)
    assert_match(/invalid type/, data_errors.first[:message])
  end

  def test_negative_length_reference
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => {},
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }

    errors = objects(schema, { 'limit' => -1, 'items' => [] })
    data_errors = errors.select { |e| e[:data_pointer] == '/limit' }

    assert_equal(1, data_errors.size)
    assert_match(/negative length/, data_errors.first[:message])
  end

  def test_fractional_length_reference_is_invalid_type
    schema = {
      'type' => 'array',
      'maxItems' => { '$data' => '/0' },
    }

    errors = strings(schema, [1.5])

    assert_equal(1, errors.size)
    assert_match(/invalid type/, errors.first)
  end

  def test_escaped_slash_and_tilde_keys
    schema = {
      'type' => 'object',
      'properties' => {
        'a/b' => { 'type' => 'integer' },
        'c~d' => { 'type' => 'integer' },
        'from_slash' => { 'type' => 'string', 'maxLength' => { '$data' => '/a~1b' } },
        'from_tilde' => { 'type' => 'string', 'maxLength' => { '$data' => '/c~0d' } },
      },
    }

    assert_valid(schema, { 'a/b' => 3, 'c~d' => 1, 'from_slash' => 'abc', 'from_tilde' => 'x' }, OPTIONS)
    refute_valid(schema, { 'a/b' => 1, 'c~d' => 1, 'from_slash' => 'ab', 'from_tilde' => '' }, OPTIONS)
  end

  def test_array_indices_in_pointer
    schema = {
      'type' => 'object',
      'properties' => {
        'limits' => { 'type' => 'array' },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limits/1' } },
      },
    }

    assert_valid(schema, { 'limits' => [0, 2], 'items' => [1, 2] }, OPTIONS)
    refute_valid(schema, { 'limits' => [0, 2], 'items' => [1, 2, 3] }, OPTIONS)

    out_of_range = objects(schema, { 'limits' => [], 'items' => [1] })

    assert_equal('/limits/1', out_of_range.first[:data_pointer])
  end

  def test_pointer_resolves_from_root_across_ref
    schema = {
      'type' => 'object',
      'definitions' => {
        'bounded' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
      'properties' => {
        'limit' => { 'type' => 'integer' },
        'items' => { '$ref' => '#/definitions/bounded' },
      },
    }

    assert_valid(schema, { 'limit' => 2, 'items' => [1, 2] }, OPTIONS)
    refute_valid(schema, { 'limit' => 2, 'items' => [1, 2, 3] }, OPTIONS)
  end

  def test_pointer_root_does_not_change_for_array_items
    schema = {
      'type' => 'array',
      'items' => { 'type' => 'integer', 'minimum' => { '$data' => '/0' } },
    }

    assert_valid(schema, [5, 5, 9], OPTIONS)
    refute_valid(schema, [5, 4], OPTIONS)
  end

  def test_non_absolute_pointer_is_rejected
    schema = { 'type' => 'array', 'maxItems' => { '$data' => 'limit' } }

    errors = objects(schema, [1])

    assert_equal(1, errors.size)
    assert_match(/absolute JSON Pointer/, errors.first[:message])
  end

  def test_extension_disabled_raises_at_validation_time
    schema = { 'type' => 'array', 'maxItems' => { '$data' => '/0' } }

    assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.validate!(schema, [1], clear_cache: true)
    end
  end

  def test_extension_disabled_statically_rejects_its_format
    schema = { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } }

    assert_raises(JSON::Schema::ValidationError) do
      JSON::Validator.new(schema, clear_cache: true, validate_schema: true)
    end
  end

  def test_extension_enabled_statically_accepts_and_rejects_format
    valid_schema = { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } }
    JSON::Validator.new(valid_schema, clear_cache: true, validate_schema: true, '$data' => true)

    [3, nil, 'relative', 'not/a/pointer'].each do |pointer|
      bad_schema = { 'type' => 'array', 'maxItems' => { '$data' => pointer } }
      assert_raises(JSON::Schema::ValidationError) do
        JSON::Validator.new(bad_schema, clear_cache: true, validate_schema: true, '$data' => true)
      end
    end

    missing_key = { 'type' => 'array', 'maxItems' => { 'x' => 1 } }
    assert_raises(JSON::Schema::ValidationError) do
      JSON::Validator.new(missing_key, clear_cache: true, validate_schema: true, '$data' => true)
    end
  end

  def test_constraints_read_original_input_regardless_of_default_insertion_order
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer', 'default' => 1 },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }
    reversed = {
      'type' => 'object',
      'properties' => {
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
        'limit' => { 'type' => 'integer', 'default' => 1 },
      },
    }
    options = OPTIONS.merge(insert_defaults: true)

    [schema, reversed].each do |candidate|
      data = { 'items' => [1, 2, 3] }
      errors = JSON::Validator.fully_validate(candidate, data, options)

      assert_equal(1, errors.size)
      assert_match(/does not exist/, errors.first)
      assert_equal(1, data['limit'])
    end
  end

  def test_concurrent_validations_do_not_share_resolved_values
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer' },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }
    validator = JSON::Validator.new(schema, OPTIONS.merge(validate_schema: false, record_errors: true))

    results = []
    mutex = Mutex.new
    threads = Array.new(8) do |thread_index|
      Thread.new do
        50.times do |i|
          limit = (thread_index + i).even? ? 1 : 4
          data = { 'limit' => limit, 'items' => [1, 2, 3] }
          errors = validator.validate(data)
          mutex.synchronize { results << [limit, errors.empty?] }
        end
      end
    end
    threads.each(&:join)

    results.each do |limit, valid|
      assert_equal(limit > 3, valid, "limit=#{limit}")
    end
  end

  def test_referenced_value_is_never_treated_as_schema_or_code
    dangerous = { '$schema' => 'http://json-schema.org/draft-04/schema#', 'evil' => true }
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => {},
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }

    errors = strings(schema, { 'limit' => dangerous, 'items' => [] })

    assert_equal(1, errors.size)
    assert_match(/invalid type/, errors.first)
  end
end
