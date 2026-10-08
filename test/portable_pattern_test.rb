require File.expand_path('support/test_helper', __dir__)

class PortablePatternTest < Minitest::Test
  PORTABLE = { portable_pattern: true }.freeze

  # ------------------------------------------------------------------
  # Cases where Ruby's Regexp and ECMAScript's RegExp disagree. Each
  # case asserts the ECMAScript result in portable mode and documents
  # the divergent Ruby interpretation.
  # ------------------------------------------------------------------

  def test_anchors_match_string_edges_not_line_edges
    schema = { 'pattern' => '^a$' }

    assert_valid(schema, 'a', PORTABLE)
    refute_valid(schema, "x\na\ny", PORTABLE)
    refute_valid(schema, "a\nb", PORTABLE)
    refute_valid(schema, "a\n", PORTABLE)

    # Ruby's ^ and $ are line anchors and would have matched:
    assert_match(Regexp.new('^a$'), "x\na\ny")
  end

  def test_dot_excludes_unicode_line_terminators
    schema = { 'pattern' => '^a.b$' }

    assert_valid(schema, 'axb', PORTABLE)
    refute_valid(schema, "a\u2028b", PORTABLE)
    refute_valid(schema, "a\u2029b", PORTABLE)

    # Ruby's . matches U+2028/U+2029:
    assert_match(Regexp.new('^a.b$'), "a\u2028b")
  end

  def test_whitespace_escape_covers_unicode_whitespace
    schema = { 'pattern' => '^\s$' }

    assert_valid(schema, ' ', PORTABLE)
    assert_valid(schema, "\u00a0", PORTABLE)
    assert_valid(schema, "\u2028", PORTABLE)
    assert_valid(schema, "\ufeff", PORTABLE)

    # Ruby's \s only covers ASCII whitespace:
    refute_match(Regexp.new('\s'), "\u00a0")
  end

  def test_posix_looking_class_is_a_plain_class
    schema = { 'pattern' => '^[[:alpha:]]$' }

    # ECMAScript reads this as the class [[:alph:] followed by a
    # literal ]; it is not a POSIX class.
    assert_valid(schema, 'a]', PORTABLE)
    refute_valid(schema, 'a', PORTABLE)

    # Ruby reads it as the POSIX class [[:alpha:]]:
    assert_match(Regexp.new('^[[:alpha:]]$'), 'a')
  end

  def test_ampersands_in_class_do_not_intersect
    schema = { 'pattern' => '^[a&&b]$' }

    assert_valid(schema, '&', PORTABLE)
    assert_valid(schema, 'a', PORTABLE)

    # Ruby reads && as class intersection, which is empty here:
    refute_match(Regexp.new('^[a&&b]$'), 'a')
  end

  def test_open_brace_comma_is_literal_not_a_quantifier
    schema = { 'pattern' => '^a{,3}$' }

    assert_valid(schema, 'a{,3}', PORTABLE)
    refute_valid(schema, 'aaa', PORTABLE)

    # Ruby treats {,3} as a quantifier:
    assert_match(Regexp.new('^a{,3}$'), 'aaa')
  end

  def test_stray_brace_after_quantifier_stays_a_literal
    assert_valid({ 'pattern' => '^a*{x$' }, 'aa{x', PORTABLE)
    assert_valid({ 'pattern' => '^a{2}{x$' }, 'aa{x', PORTABLE)
    assert_valid({ 'pattern' => '^a{$' }, 'a{', PORTABLE)
  end

  def test_unknown_letter_escape_is_a_literal
    schema = { 'pattern' => '^x\Ay$' }

    # ECMAScript identity escape: \A is a literal "A".
    assert_valid(schema, 'xAy', PORTABLE)
    refute_valid(schema, 'xy', PORTABLE)

    # Ruby reads \A as an anchor, so x\Ay can never match:
    refute_match(Regexp.new('^x\Ay$'), 'xAy')
  end

  def test_class_escape_dash_is_a_literal_dash
    schema = { 'pattern' => '^[\d-z]$' }

    assert_valid(schema, '-', PORTABLE)
    assert_valid(schema, '5', PORTABLE)
    assert_valid(schema, 'z', PORTABLE)
    refute_valid(schema, 'm', PORTABLE)

    # Ruby cannot even compile this:
    assert_raises(RegexpError) { Regexp.new('^[\d-z]$') }
  end

  def test_empty_class_never_matches_and_negated_empty_class_matches_all
    assert_kind_of Regexp, JSON::Util::PortablePattern.compile('[]')
    refute_valid({ 'pattern' => 'a[]' }, 'a', PORTABLE)
    assert_valid({ 'pattern' => 'a[^]' }, "a\n", PORTABLE)

    # Ruby rejects both forms:
    assert_raises(RegexpError) { Regexp.new('a[]') }
  end

  # ------------------------------------------------------------------
  # Cases where both engines agree; portable mode must preserve the
  # shared semantics.
  # ------------------------------------------------------------------

  def test_literal_and_unanchored_search
    schema = { 'pattern' => 'abc' }

    assert_valid(schema, 'xabcx', PORTABLE)
    refute_valid(schema, 'axbxc', PORTABLE)
  end

  def test_character_classes
    assert_valid({ 'pattern' => '^[a-c]+$' }, 'abcba', PORTABLE)
    refute_valid({ 'pattern' => '^[a-c]+$' }, 'abcd', PORTABLE)
    assert_valid({ 'pattern' => '^[^a-c]$' }, 'z', PORTABLE)
    assert_valid({ 'pattern' => '^[a\-c]$' }, '-', PORTABLE)
  end

  def test_groups_and_alternation
    schema = { 'pattern' => '^(ab|cd)+$' }

    assert_valid(schema, 'ababcd', PORTABLE)
    assert_valid(schema, 'cd', PORTABLE)
    refute_valid(schema, 'abx', PORTABLE)
    assert_valid({ 'pattern' => '^(?:cat|dog)$' }, 'dog', PORTABLE)
    assert_valid({ 'pattern' => '^()$' }, '', PORTABLE)
  end

  def test_quantifiers
    assert_valid({ 'pattern' => '^a{2,4}$' }, 'aaa', PORTABLE)
    refute_valid({ 'pattern' => '^a{2,4}$' }, 'aaaaa', PORTABLE)
    assert_valid({ 'pattern' => '^a{2,}$' }, 'aaaaa', PORTABLE)
    assert_valid({ 'pattern' => '^a{3}$' }, 'aaa', PORTABLE)
    assert_valid({ 'pattern' => 'colou?r' }, 'color', PORTABLE)
    assert_valid({ 'pattern' => 'colou?r' }, 'colour', PORTABLE)
    assert_valid({ 'pattern' => '^a*?$' }, '', PORTABLE)
    assert_valid({ 'pattern' => '^\d+?\d$' }, '123', PORTABLE)
  end

  def test_common_escapes
    assert_valid({ 'pattern' => '^\d{3}-\d{4}$' }, '555-1234', PORTABLE)
    assert_valid({ 'pattern' => '^\w+$' }, 'abc_123', PORTABLE)
    refute_valid({ 'pattern' => '^\w+$' }, 'abc-123', PORTABLE)
    assert_valid({ 'pattern' => '^\S+$' }, 'abc', PORTABLE)
    refute_valid({ 'pattern' => '^\S+$' }, 'a c', PORTABLE)
    assert_valid({ 'pattern' => '\bword\b' }, 'a word here', PORTABLE)
    refute_valid({ 'pattern' => '\bword\b' }, 'swordfish', PORTABLE)
    assert_valid({ 'pattern' => '^a\tb\nc$' }, "a\tb\nc", PORTABLE)
    assert_valid({ 'pattern' => '^\x41+$' }, 'AAA', PORTABLE)
    assert_valid({ 'pattern' => '^\u00e9$' }, 'é', PORTABLE)
    # \0 compiles to a NUL matcher (checked directly because the
    # validator's data loader cannot handle NUL bytes in string data)
    assert_match(JSON::Util::PortablePattern.compile('^\0$'), "\0")
  end

  def test_unicode_surrogate_pairs
    schema = { 'pattern' => '^\ud83d\ude00$' }

    assert_valid(schema, "\u{1F600}", PORTABLE)
    refute_valid(schema, 'x', PORTABLE)
  end

  def test_escaped_backslash_and_class_symbols_are_not_rewritten
    # A literal backslash in the pattern must survive compilation, and
    # characters that are special to Ruby inside classes must not be
    # corrupted by naive string substitution.
    assert_valid({ 'pattern' => '^a\\\\b$' }, 'a\b', PORTABLE)
    assert_valid({ 'pattern' => '^[\^]$' }, '^', PORTABLE)
    assert_valid({ 'pattern' => '^[$]$' }, '$', PORTABLE)
    assert_valid({ 'pattern' => '^[.]$' }, '.', PORTABLE)
    refute_valid({ 'pattern' => '^[.]$' }, 'x', PORTABLE)
    assert_valid({ 'pattern' => '^\$$' }, '$', PORTABLE)
    assert_valid({ 'pattern' => '^[\d]$' }, '5', PORTABLE)
    refute_valid({ 'pattern' => '^[\d]$' }, 'd', PORTABLE)
  end

  def test_pattern_properties_share_the_compiler
    schema = {
      'patternProperties' => {
        '^num_\d+$' => { 'type' => 'integer' },
        'é' => { 'type' => 'string' },
      },
    }

    assert_valid(schema, { 'num_1' => 5, 'café' => 'x' }, PORTABLE)
    refute_valid(schema, { 'num_1' => 'x' }, PORTABLE)
    # Keys are matched against the ECMAScript meaning: a multi-line key
    # does not satisfy the anchors mid-string, so no subschema applies.
    assert_valid(schema, { "x\nnum_1" => 'not-an-integer-but-no-match' }, PORTABLE)
    # Ruby's line anchors would match the key and apply the subschema:
    refute_valid(schema, "x\nnum_1" => 'not-an-integer-but-no-match')
  end

  def test_default_mode_is_unchanged
    schema = { 'pattern' => '^a$' }

    # Without portable_pattern the Ruby interpretation still applies.
    assert_valid(schema, "x\na\ny")
  end

  # ------------------------------------------------------------------
  # Syntax that cannot be compiled equivalently is rejected while the
  # schema is being prepared, with the error pointing at the pattern's
  # location in the schema.
  # ------------------------------------------------------------------

  def assert_schema_error(pattern, key = 'pattern')
    schema = { 'properties' => { 'foo' => { key => pattern } } }
    error = assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.new(schema, portable_pattern: true)
    end
    assert_match(%r{#/properties/foo/#{Regexp.escape(key.to_s)}}, error.message)
    error
  end

  def test_backreferences_are_rejected
    assert_schema_error('(a)\1')
  end

  def test_lookaround_is_rejected
    assert_schema_error('a(?=b)')
    assert_schema_error('a(?!b)')
    assert_schema_error('(?<=a)b')
    assert_schema_error('(?<!a)b')
  end

  def test_named_groups_are_rejected
    assert_schema_error('(?<name>a)')
    assert_schema_error('(?<name>a)\k<name>')
  end

  def test_possessive_and_stacked_quantifiers_are_rejected
    assert_schema_error('a*+')
    assert_schema_error('a**')
    assert_schema_error('a{2}{3}')
  end

  def test_octal_and_control_escapes_are_rejected
    assert_schema_error('\041')
    assert_schema_error('\ca')
  end

  def test_lone_surrogates_are_rejected
    assert_schema_error('\ud800')
    assert_schema_error('\udc00x')
  end

  def test_negated_whitespace_in_class_is_rejected
    assert_schema_error('[\S]')
  end

  def test_invalid_patterns_are_rejected
    assert_schema_error('[z-a]')
    assert_schema_error('[a')
    assert_schema_error('(a')
    assert_schema_error('a{3}{2}')
    assert_schema_error('a\\')
  end

  def test_pattern_properties_keys_are_checked_with_location
    schema = { 'patternProperties' => { 'x(?=y)' => {} } }
    error = assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.new(schema, portable_pattern: true)
    end
    assert_match(%r{#/patternProperties/x\(\?=y\)}, error.message)
  end

  def test_unsupported_pattern_does_not_fall_back_to_ruby
    # '(a)\1' is a perfectly valid Ruby regexp; portable mode must
    # reject it instead of silently using Ruby's interpretation.
    assert_match Regexp.new('(a)\1'), 'aa'
    assert_schema_error('(a)\1')
  end

  def test_nested_schema_locations_are_reported
    schema = {
      'properties' => {
        'items' => {
          'items' => { 'pattern' => 'a(?=b)' },
        },
      },
    }
    error = assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.new(schema, portable_pattern: true)
    end
    assert_match(%r{#/properties/items/items/pattern}, error.message)
  end

  def test_validate_bang_raises_schema_error
    schema = { 'pattern' => '(a)\1' }

    assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.validate!(schema, 'aa', portable_pattern: true)
    end
  end
end
