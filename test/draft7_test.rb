require File.expand_path('support/test_helper', __dir__)

class Draft7Test < Minitest::Test
  def validation_errors(schema, data, options = {})
    super(schema, data, { version: :draft7 }.merge(options))
  end

  def draft7_schema(name)
    File.expand_path("schemas/draft7/#{name}.json", __dir__)
  end

  def test_draft7_validator_is_separately_registered
    validator = JSON::Validator.validator_for_uri('http://json-schema.org/draft-07/schema#')

    assert_instance_of JSON::Schema::Draft7, validator
    assert_includes validator.names, 'draft7'
    assert_includes validator.names, 'http://json-schema.org/draft-07/schema#'
  end

  def test_default_dialect_is_unchanged
    assert_instance_of JSON::Schema::Draft6, JSON::Validator.default_validator
  end

  def test_schema_declaring_draft7_does_not_fall_back_to_draft6
    schema = { '$schema' => 'http://json-schema.org/draft-07/schema#', 'contains' => { 'type' => 'integer' } }

    assert_valid(schema, [1, 'x'])
    refute_valid(schema, %w[x y])
  end

  def test_draft7_keywords_are_ignored_under_draft6
    schema = { 'contains' => false }

    assert_valid(schema, [], version: :draft6, validate_schema: false)
    assert_empty JSON::Validator.fully_validate(schema, [],
                                                parse_data: false, clear_cache: true,
                                                validate_schema: false)
  end

  def test_boolean_root_schemas
    assert_valid(true, 42, version: :draft7)
    assert_valid(true, 'anything', version: :draft7)
    refute_valid(false, 42, version: :draft7)
    refute_valid(false, nil, version: :draft7)
  end

  def test_boolean_subschemas_from_local_samples
    schema = draft7_schema('boolean_schemas')

    assert_valid(schema, { 'anything' => 1, 'nested' => { 'allowed' => 'x' } })
  end

  def test_boolean_property_false_rejects_with_accurate_path
    schema = draft7_schema('boolean_schemas')

    errors = JSON::Validator.fully_validate(schema,
                                            { 'nothing' => 1 },
                                            parse_data: false, clear_cache: true,
                                            validate_schema: true, version: :draft7,
                                            errors_as_objects: true)

    assert_equal 1, errors.length
    assert_equal '#/nothing', errors.first[:fragment]
    assert_equal 'FalseSchema', errors.first[:failed_attribute]
  end

  def test_boolean_nested_false_path
    schema = draft7_schema('boolean_schemas')

    errors = JSON::Validator.fully_validate(schema,
                                            { 'nested' => { 'forbidden' => 1 } },
                                            parse_data: false, clear_cache: true,
                                            validate_schema: true, version: :draft7,
                                            errors_as_objects: true)

    assert_equal '#/nested/forbidden', errors.first[:fragment]
  end

  def test_boolean_items
    schema = draft7_schema('boolean_schemas')

    assert_valid(schema, { 'list' => [] })
    refute_valid(schema, { 'list' => [1] })

    errors = JSON::Validator.fully_validate(schema,
                                            { 'list' => [1] },
                                            parse_data: false, clear_cache: true,
                                            validate_schema: true, version: :draft7,
                                            errors_as_objects: true)

    assert_equal '#/list/0', errors.first[:fragment]
  end

  def test_if_then_else_samples
    schema = draft7_schema('if_then_else')

    assert_valid(schema, { 'kind' => 'business', 'department' => 'engineering' })
    assert_valid(schema, { 'kind' => 'residential', 'hometown' => 'Berlin' })

    refute_valid(schema, { 'kind' => 'business' })
    refute_valid(schema, { 'kind' => 'residential' })
  end

  def test_if_failure_is_not_reported_when_no_else
    schema = {
      'if' => { 'type' => 'string' },
      'then' => { 'const' => 'yes' },
    }

    # if fails for a number, there is no else, so the schema passes
    assert_valid(schema, 42)

    # if passes for a string, then is enforced
    errors = validation_errors(schema, 'no').map { |e| e }

    assert_equal 1, errors.length
    assert_match(/constant 'yes'/, errors.first)
  end

  def test_missing_then_and_else
    schema = { 'if' => { 'type' => 'string' } }

    assert_valid(schema, 'a string')
    assert_valid(schema, 42)
  end

  def test_boolean_if_then_else_branches
    refute_valid({ 'if' => true, 'then' => false }, 1)
    refute_valid({ 'if' => false, 'else' => false }, 1)
    assert_valid({ 'if' => false, 'then' => false }, 1)
    assert_valid({ 'if' => true, 'else' => false }, 1)
  end

  def test_contains_samples
    schema = draft7_schema('contains')

    assert_valid(schema, [1, 'x', 7])
    assert_valid(schema, [5])
    refute_valid(schema, [1, 2, 3])
    refute_valid(schema, %w[x y])
    refute_valid(schema, [])
  end

  def test_contains_failure_keeps_limited_positioned_sub_errors
    schema = draft7_schema('contains')
    data = (1..10).map(&:to_s)

    errors = JSON::Validator.fully_validate(schema, data,
                                            parse_data: false, clear_cache: true,
                                            validate_schema: true, version: :draft7,
                                            errors_as_objects: true)

    assert_equal 1, errors.length
    assert_equal '#/', errors.first[:fragment]
    assert_equal 'Contains', errors.first[:failed_attribute]

    sub = errors.first[:errors]

    assert_equal JSON::Schema::ContainsAttribute::MAX_RETAINED_ITEM_ERRORS, sub.length
    fragments = sub.values.flat_map { |item_errors| item_errors.map { |e| e[:fragment] } }

    expected = (0...JSON::Schema::ContainsAttribute::MAX_RETAINED_ITEM_ERRORS).map { |i| ['#/', i].join }

    assert_equal expected, fragments
    assert_nil(sub.values.flatten.find { |e| e[:fragment] == '#/5' })
  end

  def test_contains_with_boolean_subschema
    assert_valid({ 'contains' => true }, [1], version: :draft7)
    refute_valid({ 'contains' => true }, [], version: :draft7)
    refute_valid({ 'contains' => false }, [1], version: :draft7)
  end

  def test_ref_with_dollar_id_uses_base_uri
    schema = draft7_schema('ref_with_id')

    assert_valid(schema, { 'number' => 5 })
    refute_valid(schema, { 'number' => -1 })
    refute_valid(schema, { 'number' => 'x' })
  end

  def test_referenced_subschema_keeps_draft7_dialect
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'definitions' => {
        'conditional' => {
          'if' => { 'type' => 'string' },
          'then' => { 'minLength' => 3 },
        },
      },
      '$ref' => '#/definitions/conditional',
    }

    assert_valid(schema, 'abc')
    refute_valid(schema, 'ab')
    # if fails, no else -> number is valid
    assert_valid(schema, 5)
  end

  def test_schema_looking_objects_in_enum_are_not_traversed
    schema = draft7_schema('enum_default_objects')

    assert_valid(schema, { 'kind' => { 'type' => 'string', 'minLength' => 1 } })
    refute_valid(schema, { 'kind' => { 'type' => 'unknown' } })
    # the object-looking default is data, never validated as a schema
    assert_valid(schema, { 'with_default' => {} })
  end

  def test_default_object_is_not_validated_as_schema
    schema = {
      'type' => 'object',
      'properties' => {
        'x' => {
          'type' => 'string',
          'default' => { 'properties' => { 'y' => false } },
        },
      },
    }

    assert_valid(schema, {})
  end

  def test_draft7_metaschema_is_local
    path = JSON::Validator.validator_for_name(:draft7).metaschema

    assert_path_exists(path)
    assert_match(/draft-07\.json\z/, path)
    assert_equal File.expand_path('../resources/draft-07.json', __dir__), path
  end

  def test_no_external_meta_schema_requests
    # No stub is registered for the meta-schema host: any HTTP request fails.
    assert_valid({ '$schema' => 'http://json-schema.org/draft-07/schema#', 'type' => 'integer' }, 3)
  end

  def test_draft7_metaschema_validates_draft7_schema_offline
    stub_request(:any, /example\.com/)
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'type' => 'object',
      'properties' => { 'a' => { 'contains' => { 'if' => true, 'then' => false } } },
    }

    # validate_schema alone confirms the meta-schema accepts the draft7 keywords
    assert_valid(schema, {})
  end

  def test_boolean_schema_dependency
    schema = {
      'type' => 'object',
      'dependencies' => {
        'a' => false,
        'b' => true,
      },
    }

    assert_valid(schema, { 'b' => 1 })
    refute_valid(schema, { 'a' => 1 })
    assert_valid(schema, {})
  end
end
