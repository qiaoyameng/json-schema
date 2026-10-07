require File.expand_path('support/test_helper', __dir__)

class DataPointerTest < Minitest::Test
  def items_schema
    {
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer' },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }
  end

  def test_max_items_limit_taken_from_data
    assert_valid(items_schema, { 'limit' => 2, 'items' => [1, 2] }, data: true)
    refute_valid(items_schema, { 'limit' => 1, 'items' => [1, 2] }, data: true)
  end

  def test_max_length_limit_taken_from_data
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer' },
        'name' => { 'type' => 'string', 'maxLength' => { '$data' => '/limit' } },
      },
    }

    assert_valid(schema, { 'limit' => 3, 'name' => 'abc' }, data: true)
    refute_valid(schema, { 'limit' => 2, 'name' => 'abc' }, data: true)
  end

  def test_maximum_and_minimum_taken_from_data
    schema = {
      'type' => 'object',
      'properties' => {
        'lo' => { 'type' => 'number' },
        'hi' => { 'type' => 'number' },
        'value' => {
          'type' => 'number',
          'minimum' => { '$data' => '/lo' },
          'maximum' => { '$data' => '/hi' },
        },
      },
    }

    assert_valid(schema, { 'lo' => 1.5, 'hi' => 3, 'value' => 2 }, data: true)
    refute_valid(schema, { 'lo' => 1.5, 'hi' => 3, 'value' => 1 }, data: true)
    refute_valid(schema, { 'lo' => 1.5, 'hi' => 3, 'value' => 4 }, data: true)
  end

  def test_missing_referenced_value_is_an_error
    errors = validation_errors(items_schema, { 'items' => [1] }, data: true)

    assert_equal(1, errors.length)
    assert_match(/maxItems/, errors.first)
    assert_match(%r{/limit}, errors.first)
    assert_match(/does not exist/, errors.first)
    assert_match(%r{#/items}, errors.first)
  end

  def test_null_referenced_value_is_an_error
    errors = validation_errors(items_schema, { 'limit' => nil, 'items' => [1] }, data: true)

    assert(errors.any? { |e| e.include?('maxItems') && e.include?('/limit') && e.include?('is null') })
  end

  def test_non_numeric_referenced_value_is_an_error
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => {},
        'value' => { 'maximum' => { '$data' => '/limit' } },
      },
    }
    errors = validation_errors(schema, { 'limit' => '3', 'value' => 2 }, data: true)

    assert(errors.any? { |e| e.include?('maximum') && e.include?('/limit') && e.include?('is not a number') })
  end

  def test_non_integer_referenced_value_is_an_error_for_lengths
    errors = validation_errors(items_schema, { 'limit' => 1.5, 'items' => [1] }, data: true)

    assert(errors.any? { |e| e.include?('maxItems') && e.include?('/limit') && e.include?('is not an integer') })
  end

  def test_negative_referenced_length_is_an_error
    errors = validation_errors(items_schema, { 'limit' => -1, 'items' => [1] }, data: true)

    assert(errors.any? { |e| e.include?('maxItems') && e.include?('/limit') && e.include?('negative') })
  end

  def test_pointer_with_escaped_keys
    schema = {
      'type' => 'object',
      'properties' => {
        'a/b' => { 'type' => 'integer' },
        'c~d' => { 'type' => 'integer' },
        'name' => { 'type' => 'string', 'maxLength' => { '$data' => '/a~1b' } },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/c~0d' } },
      },
    }

    assert_valid(schema, { 'a/b' => 2, 'c~d' => 1, 'name' => 'ab', 'items' => [1] }, data: true)
    refute_valid(schema, { 'a/b' => 2, 'c~d' => 1, 'name' => 'abc', 'items' => [1] }, data: true)
    refute_valid(schema, { 'a/b' => 2, 'c~d' => 1, 'name' => 'ab', 'items' => [1, 2] }, data: true)
  end

  def test_pointer_with_array_index
    schema = {
      'type' => 'object',
      'properties' => {
        'limits' => { 'type' => 'array' },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limits/1' } },
      },
    }

    assert_valid(schema, { 'limits' => [0, 2], 'items' => [1, 2] }, data: true)
    refute_valid(schema, { 'limits' => [0, 1], 'items' => [1, 2] }, data: true)

    errors = validation_errors(schema, { 'limits' => [0], 'items' => [1] }, data: true)

    assert(errors.any? { |e| e.include?('/limits/1') && e.include?('does not exist') })
  end

  def test_pointer_resolves_against_root_inside_ref
    schema = {
      'definitions' => {
        'capped' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer' },
        'items' => { '$ref' => '#/definitions/capped' },
      },
    }

    assert_valid(schema, { 'limit' => 2, 'items' => [1, 2] }, data: true)
    refute_valid(schema, { 'limit' => 1, 'items' => [1, 2] }, data: true)
  end

  def test_pointer_resolves_against_root_inside_array_items
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer' },
        'rows' => {
          'type' => 'array',
          'items' => { 'type' => 'string', 'maxLength' => { '$data' => '/limit' } },
        },
      },
    }

    assert_valid(schema, { 'limit' => 2, 'rows' => %w[ab cd] }, data: true)
    refute_valid(schema, { 'limit' => 2, 'rows' => %w[ab cde] }, data: true)
  end

  def test_references_read_original_input_not_inserted_defaults
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => { 'type' => 'integer', 'default' => 5 },
        'items' => { 'type' => 'array', 'maxItems' => { '$data' => '/limit' } },
      },
    }
    errors = validation_errors(schema, { 'items' => [1] }, data: true, insert_defaults: true)

    assert(errors.any? { |e| e.include?('/limit') && e.include?('does not exist') })
  end

  def test_referenced_value_is_never_treated_as_schema
    schema = {
      'type' => 'object',
      'properties' => {
        'limit' => {},
        'value' => { 'maximum' => { '$data' => '/limit' } },
      },
    }
    errors = validation_errors(schema, { 'limit' => { '$ref' => '#/definitions/x' }, 'value' => 2 }, data: true)

    assert(errors.any? { |e| e.include?('is not a number') })
  end

  def test_schema_validation_accepts_data_references_when_enabled
    assert_empty(JSON::Validator.fully_validate_schema(items_schema, data: true))
    assert_valid(items_schema, { 'limit' => 1, 'items' => [1] }, data: true, validate_schema: true)
  end

  def test_schema_validation_rejects_data_references_when_disabled
    refute_empty(JSON::Validator.fully_validate_schema(items_schema))
  end

  def test_runtime_rejects_data_references_when_disabled
    refute(JSON::Validator.validate(items_schema, { 'limit' => 2, 'items' => [1, 2] }))
    assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.validate!(items_schema, { 'limit' => 2, 'items' => [1, 2] })
    end
  end

  def test_unsupported_keyword_with_data_reference
    schema = { 'minItems' => { '$data' => '/limit' } }

    assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.validate!(schema, [1, 2], data: true)
    end
  end

  def test_invalid_pointer_format
    schema = { 'maxItems' => { '$data' => 'limit' } }

    assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.validate!(schema, [1, 2], data: true)
    end
  end

  def test_concurrent_validations_do_not_share_resolved_values
    validator = JSON::Validator.new(items_schema, data: true, record_errors: true)
    results = []
    mutex = Mutex.new
    threads = Array.new(8) do |t|
      Thread.new do
        item = [1]
        100.times do |i|
          limit = (t + i) % 4
          good = { 'limit' => limit, 'items' => item * limit }
          bad = { 'limit' => limit, 'items' => item * (limit + 1) }
          ok = JSON::Validator.validate(items_schema, good, data: true) &&
               !JSON::Validator.validate(items_schema, bad, data: true) &&
               validator.validate(good).empty? &&
               validator.validate(bad).length == 1
          mutex.synchronize { results << ok }
        end
      end
    end
    threads.each(&:join)

    assert_equal(800, results.length)
    assert_predicate(results, :all?)
  end
end
