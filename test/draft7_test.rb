require File.expand_path('support/test_helper', __dir__)

class Draft7Test < Minitest::Test
  def validation_errors(schema, data, _options)
    super(schema, data, version: :draft7)
  end

  def test_draft7_is_registered_but_not_the_default
    assert_instance_of(JSON::Schema::Draft7, JSON::Validator.validator_for_name(:draft7))
    assert_instance_of(JSON::Schema::Draft7, JSON::Validator.validator_for_uri('http://json-schema.org/draft-07/schema#'))
    assert_instance_of(JSON::Schema::Draft6, JSON::Validator.default_validator)
  end

  def test_schema_declaring_draft7_does_not_fall_back_to_draft6
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'contains' => { 'const' => 1 },
    }

    refute_valid schema, [2, 3]

    # Without the $schema declaration the default dialect (draft 6) does
    # not know `contains` and ignores it
    schema.delete('$schema')

    assert(JSON::Validator.validate(schema, [2, 3]))
    assert(JSON::Validator.validate(schema, [1]))
  end

  def test_boolean_schemas
    assert_valid true, 1
    assert_valid true, nil
    refute_valid false, 1
    refute_valid false, nil
  end

  def test_boolean_subschemas
    schema = {
      'properties' => { 'foo' => true, 'bar' => false },
    }

    assert_valid schema, { 'foo' => 1 }
    refute_valid schema, { 'bar' => 1 }

    schema = { 'items' => false }

    assert_valid schema, []
    refute_valid schema, [1]
  end

  def test_if_then_else_branch_selection
    schema = {
      'if' => { 'type' => 'string' },
      'then' => { 'const' => 'yes' },
      'else' => { 'const' => 1 },
    }

    assert_valid schema, 'yes'
    refute_valid schema, 'no'
    assert_valid schema, 1
    refute_valid schema, 2
  end

  def test_if_then_else_with_boolean_if
    assert_valid({ 'if' => true, 'then' => { 'const' => 1 }, 'else' => { 'const' => 2 } }, 1)
    assert_valid({ 'if' => false, 'then' => { 'const' => 1 }, 'else' => { 'const' => 2 } }, 2)
  end

  def test_lone_if_then_else_are_ignored
    assert_valid({ 'if' => { 'const' => 0 } }, 'anything')
    assert_valid({ 'then' => { 'const' => 0 } }, 'anything')
    assert_valid({ 'else' => { 'const' => 0 } }, 'anything')
  end

  def test_if_failures_do_not_enter_the_reported_errors
    schema = {
      'if' => { 'type' => 'string' },
      'else' => { 'const' => 1 },
    }

    errors = validation_errors(schema, 2, {})

    assert_equal(1, errors.length)
    assert_match(/did not match constant/, errors.first)
    refute_match(/string/, errors.first)

    # When `if` fails and no `else` is present, there is no error at all
    assert_valid({ 'if' => { 'type' => 'string' } }, 2)
  end

  def test_if_then_else_error_path
    schema = {
      'properties' => {
        'x' => {
          'if' => { 'type' => 'string' },
          'then' => { 'const' => 'a' },
          'else' => { 'const' => 1 },
        },
      },
    }

    errors = validation_errors(schema, { 'x' => 2 }, {})

    assert_equal(1, errors.length)
    assert_match(%r{#/x}, errors.first)
  end

  def test_contains
    schema = { 'contains' => { 'const' => 5 } }

    assert_valid schema, [3, 4, 5]
    refute_valid schema, [3, 4]
    refute_valid schema, []
    assert_valid schema, 'not an array'
  end

  def test_contains_error_paths
    schema = {
      'properties' => {
        'list' => { 'contains' => { 'const' => 5 } },
      },
    }

    errors = JSON::Validator.fully_validate(schema, { 'list' => %w[a b] },
                                            version: :draft7,
                                            validate_schema: true,
                                            clear_cache: true,
                                            errors_as_objects: true)

    assert_equal(1, errors.length)
    assert_equal('#/list', errors.first[:fragment])

    sub_errors = errors.first[:errors].values

    assert_equal(2, sub_errors.length)
    assert_equal('#/list/0', sub_errors[0].first[:fragment])
    assert_equal('#/list/1', sub_errors[1].first[:fragment])
  end

  def test_contains_sub_errors_are_limited
    schema = { 'contains' => { 'const' => 999 } }

    errors = JSON::Validator.fully_validate(schema, (1..10).to_a,
                                            version: :draft7,
                                            validate_schema: true,
                                            clear_cache: true,
                                            errors_as_objects: true)

    assert_equal(1, errors.length)
    assert_operator(errors.first[:errors].length, :<=, JSON::Schema::ContainsAttribute::MAX_RECORDED_SUB_ERRORS)
    assert_equal('#/0', errors.first[:errors].values.first.first[:fragment])
  end

  def test_exclusive_maximum_and_minimum
    assert_valid({ 'exclusiveMaximum' => 3 }, 2)
    refute_valid({ 'exclusiveMaximum' => 3 }, 3)
    assert_valid({ 'exclusiveMinimum' => 3 }, 4)
    refute_valid({ 'exclusiveMinimum' => 3 }, 3)
  end

  def test_id_registers_schema_uris
    schema = {
      '$id' => 'http://example.com/draft7/root.json',
      'definitions' => {
        'thing' => { '$id' => 'thing.json', 'type' => 'integer' },
      },
    }

    JSON::Validator.clear_cache
    JSON::Validator.new(schema, version: :draft7)

    assert(JSON::Validator.schema_for_uri('http://example.com/draft7/root.json'))
    assert(JSON::Validator.schema_for_uri('http://example.com/draft7/thing.json'))
  ensure
    JSON::Validator.clear_cache
  end

  def test_referenced_subschemas_keep_dialect_and_base_uri
    schema = {
      '$id' => 'http://example.com/draft7/root.json',
      'definitions' => {
        'thing' => {
          '$id' => 'thing.json',
          # `if`/`then`/`else` only exist in draft 7; if the referenced
          # schema were validated with the wrong dialect they would be
          # silently ignored
          'if' => { 'type' => 'string' },
          'then' => { 'const' => 'x' },
          'else' => { 'const' => 1 },
        },
      },
      'properties' => { 'a' => { '$ref' => 'thing.json' } },
    }

    assert_valid schema, { 'a' => 'x' }
    assert_valid schema, { 'a' => 1 }
    refute_valid schema, { 'a' => 'y' }
    refute_valid schema, { 'a' => 2 }
  end

  def test_nested_ids_change_the_base_uri_of_relative_refs
    schema = {
      '$id' => 'http://example.com/draft7/root.json',
      'definitions' => {
        'level1' => {
          '$id' => 'nested/level1.json',
          'definitions' => {
            'level2' => { '$id' => 'level2.json', 'type' => 'integer' },
          },
          '$ref' => 'level2.json',
        },
      },
      'properties' => { 'a' => { '$ref' => 'nested/level1.json' } },
    }

    JSON::Validator.clear_cache
    JSON::Validator.new(schema, version: :draft7)

    assert(JSON::Validator.schema_for_uri('http://example.com/draft7/nested/level1.json'))
    assert(JSON::Validator.schema_for_uri('http://example.com/draft7/nested/level2.json'))

    assert_valid schema, { 'a' => 5 }
    refute_valid schema, { 'a' => 'x' }
  ensure
    JSON::Validator.clear_cache
  end

  def test_default_and_enum_values_are_not_traversed_as_subschemas
    schema = {
      'definitions' => {
        'real' => { '$id' => 'http://example.com/draft7/real.json', 'type' => 'string' },
      },
      'properties' => {
        'a' => {
          'default' => { '$id' => 'http://example.com/draft7/not-a-schema.json', 'type' => 'string' },
          'enum' => [{ '$id' => 'http://example.com/draft7/also-not-a-schema.json' }, 'plain'],
        },
      },
    }

    JSON::Validator.clear_cache
    JSON::Validator.new(schema, version: :draft7, validate_schema: true)

    # Control: $id inside an actual subschema is registered
    assert(JSON::Validator.schema_for_uri('http://example.com/draft7/real.json'))
    # $id-looking objects inside `default`/`enum` values are plain data
    assert_nil(JSON::Validator.schema_for_uri('http://example.com/draft7/not-a-schema.json'))
    assert_nil(JSON::Validator.schema_for_uri('http://example.com/draft7/also-not-a-schema.json'))

    assert_valid schema, {}
    assert_valid schema, { 'a' => { '$id' => 'http://example.com/draft7/also-not-a-schema.json' } }
    assert_valid schema, { 'a' => 'plain' }
    refute_valid schema, { 'a' => 'other' }
  ensure
    JSON::Validator.clear_cache
  end

  def test_schema_validation_uses_the_local_metaschema
    # WebMock raises if any external request is attempted, so a passing
    # run proves the draft 7 meta-schema is read from local resources
    assert_empty(JSON::Validator.fully_validate_schema({ 'type' => 'string' }, version: :draft7))
    assert_empty(JSON::Validator.fully_validate_schema(true, version: :draft7))
    refute_empty(JSON::Validator.fully_validate_schema({ 'type' => 'definitely-not-a-type' }, version: :draft7))
  end
end
