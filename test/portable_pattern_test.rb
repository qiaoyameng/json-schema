# frozen_string_literal: true

require File.expand_path('support/test_helper', __dir__)

class PortablePatternTest < Minitest::Test
  PORTABLE = { portable_patterns: true, parse_integer: false }.freeze

  def pattern_schema(pattern)
    { 'type' => 'string', 'pattern' => pattern }
  end

  def assert_schema_error(schema, fragment)
    error = assert_raises(JSON::Schema::SchemaError) do
      JSON::Validator.new(schema, portable_patterns: true)
    end
    assert_includes(error.message, fragment)
    error
  end

  # Patterns whose meaning is the same in ECMAScript and Ruby must simply
  # keep working in portable mode.

  def test_literals_groups_alternation_and_quantifiers
    schema = pattern_schema('^(foo|bar)+$')

    assert_valid(schema, 'foo', PORTABLE)
    assert_valid(schema, 'foobar', PORTABLE)
    refute_valid(schema, 'fo', PORTABLE)
    refute_valid(schema, 'foo1', PORTABLE)
  end

  def test_non_capturing_groups_and_lazy_quantifiers
    assert_valid(pattern_schema('^(?:ab|cd)+$'), 'abcdab', PORTABLE)
    refute_valid(pattern_schema('^(?:ab|cd)+$'), 'ac', PORTABLE)

    assert_valid(pattern_schema('^a+?b$'), 'aab', PORTABLE)
    assert_valid(pattern_schema('^a+?b$'), 'ab', PORTABLE)
    refute_valid(pattern_schema('^a+?b$'), 'aa', PORTABLE)
  end

  def test_character_classes
    schema = pattern_schema('^[a-z][a-z0-9_]*$')

    assert_valid(schema, 'abc_9', PORTABLE)
    refute_valid(schema, '9abc', PORTABLE)
    refute_valid(schema, 'abC', PORTABLE)

    assert_valid(pattern_schema('^[^0-9]+$'), 'abc', PORTABLE)
    refute_valid(pattern_schema('^[^0-9]+$'), 'ab1', PORTABLE)
  end

  def test_common_escapes
    assert_valid(pattern_schema('^\d{2,4}$'), '12', PORTABLE)
    refute_valid(pattern_schema('^\d{2,4}$'), '12345', PORTABLE)
    refute_valid(pattern_schema('^\d{2,4}$'), '1a', PORTABLE)

    assert_valid(pattern_schema('^\w+$'), 'Word_9', PORTABLE)
    refute_valid(pattern_schema('^\w+$'), 'no spaces', PORTABLE)

    assert_valid(pattern_schema('^\x41\tB$'), "A\tB", PORTABLE)
    assert_valid(pattern_schema('^\u0041\u0042$'), 'AB', PORTABLE)
    refute_valid(pattern_schema('^\u0041\u0042$'), 'AC', PORTABLE)
    assert_valid(pattern_schema('^\cA$'), "\u{1}", PORTABLE)

    assert_valid(pattern_schema('^\bword\b$'), 'word', PORTABLE)
    refute_valid(pattern_schema('^\bword\b$'), 'sword', PORTABLE)
  end

  def test_nul_escape
    regexp = JSON::Util::PortablePattern.compile('^a\0b$')

    assert_match(regexp, "a\u{0}b")
    refute_match(regexp, 'ab')
  end

  def test_escaped_syntax_characters
    schema = pattern_schema('^a\.b\(\)\|$')

    assert_valid(schema, 'a.b()|', PORTABLE)
    refute_valid(schema, 'aXb()|', PORTABLE)
  end

  def test_unicode_literals
    schema = pattern_schema('^日本+$')

    assert_valid(schema, '日本本', PORTABLE)
    refute_valid(schema, '日本語', PORTABLE)
  end

  def test_unanchored_search
    schema = pattern_schema('\d+')

    assert_valid(schema, 'abc123', PORTABLE)
    refute_valid(schema, 'abc', PORTABLE)
  end

  def test_empty_pattern_matches_everything
    assert_valid(pattern_schema(''), 'anything', PORTABLE)
  end

  def test_empty_character_classes
    # ECMAScript `[]` never matches, `[^]` matches any character
    refute_valid(pattern_schema('[]'), 'a', PORTABLE)
    assert_valid(pattern_schema('a[^]b'), "a\nb", PORTABLE)
  end

  # Patterns where Ruby's Regexp and ECMAScript mean different things:
  # portable mode must follow ECMAScript.

  def test_anchors_match_string_ends_not_line_ends
    schema = pattern_schema('^a$')

    refute_valid(schema, "b\na", PORTABLE)
    refute_valid(schema, "a\nb", PORTABLE)
    refute_valid(schema, "a\n", PORTABLE)
    assert_valid(schema, 'a', PORTABLE)

    # without the option the historical Ruby semantics are kept
    assert_valid(schema, "b\na")
    assert_valid(schema, "a\nb")
    assert_valid(schema, "a\n")
  end

  def test_dot_excludes_all_ecmascript_line_terminators
    schema = pattern_schema('^.$')

    assert_valid(schema, 'a', PORTABLE)
    refute_valid(schema, "\n", PORTABLE)
    refute_valid(schema, "\r", PORTABLE)
    refute_valid(schema, "\u{2028}", PORTABLE)
    refute_valid(schema, "\u{2029}", PORTABLE)

    # Ruby's `.` matches "\r" and U+2028/U+2029
    assert_valid(schema, "\r")
    assert_valid(schema, "\u{2028}")
  end

  def test_dot_matches_a_whole_unicode_character
    assert_valid(pattern_schema('^.$'), "\u{1F600}", PORTABLE)
  end

  def test_whitespace_escape_covers_unicode_spaces
    schema = pattern_schema('^\s+$')

    assert_valid(schema, "\u{a0}\u{3000}", PORTABLE)
    assert_valid(schema, " \t", PORTABLE)

    # Ruby's `\s` does not match U+00A0 or U+3000
    refute_valid(schema, "\u{a0}\u{3000}")
  end

  def test_identity_escapes_are_literal_characters
    # `\A` is not an ECMAScript escape; it stands for a literal "A"
    schema = pattern_schema('\A')

    assert_valid(schema, 'A', PORTABLE)
    assert_valid(schema, 'BA', PORTABLE)
    refute_valid(schema, 'B', PORTABLE)

    # Ruby reads `\A` as the start-of-string anchor, matching anywhere
    assert_valid(schema, 'B')
  end

  def test_identity_escape_z
    schema = pattern_schema('\z')

    assert_valid(schema, 'z', PORTABLE)
    refute_valid(schema, 'a', PORTABLE)

    # Ruby reads `\z` as the end-of-string anchor
    assert_valid(schema, 'a')
  end

  def test_identity_escape_e
    schema = pattern_schema('\e')

    assert_valid(schema, 'e', PORTABLE)
    refute_valid(schema, "\u{1b}", PORTABLE)

    # Ruby reads `\e` as the escape character
    assert_valid(schema, "\u{1b}")
  end

  def test_no_silent_fallback_to_ruby_semantics
    # `a*+` is a possessive quantifier in Ruby; portable mode rejects it
    # instead of silently using Ruby's reading
    assert_schema_error(pattern_schema('a*+'), '#/pattern')
  end

  # Unsupported constructs are rejected while the schema is being prepared,
  # with an error pointing at the pattern's location in the schema.

  def test_unsupported_constructs_are_rejected_at_preparation_time
    unsupported = [
      '(a)\1',          # backreference
      '\k<name>',       # named backreference
      '\07',            # legacy octal escape
      'a(?=b)',         # lookahead
      'a(?!b)',         # negative lookahead
      '(?<=a)b',        # lookbehind
      '(?<!a)b',        # negative lookbehind
      '(?<name>a)',     # named capture group
      '\uD83D\uDE00', # UTF-16 surrogate pair escapes
      '^*',             # quantified assertion
      '\b+',            # quantified assertion
      'a*+',            # stacked quantifiers
      'a??+',           # stacked quantifiers
      'a{2,1}',         # out of order quantifier range
      '(a',             # unterminated group
      '[a',             # unterminated character class
      'a\\',            # trailing backslash
      ')',              # unmatched parenthesis
      '[[:alpha:]]',    # POSIX class (Ruby-only meaning)
      '[a&&b]',         # class intersection (Ruby-only meaning)
      '[z-a]',          # out of order character range
    ]

    unsupported.each do |pattern|
      error = assert_raises(JSON::Schema::SchemaError, "expected #{pattern.inspect} to be rejected") do
        JSON::Validator.new(pattern_schema(pattern), portable_patterns: true)
      end
      assert_includes(error.message, '#/pattern')
    end
  end

  def test_error_points_at_nested_pattern_location
    schema = { 'properties' => { 'a' => { 'pattern' => '(a)\1' } } }

    assert_schema_error(schema, '#/properties/a/pattern')
  end

  def test_error_points_at_pattern_in_array_subschema
    schema = { 'items' => [{ 'pattern' => 'a(?=b)' }] }

    assert_schema_error(schema, '#/items/0/pattern')
  end

  def test_error_reports_pattern_and_offset
    error = assert_schema_error(pattern_schema('(a)\1'), '#/pattern')

    assert_includes(error.message, '(a)\\\\1')
    assert_includes(error.message, 'offset 3')
  end

  def test_unsupported_constructs_are_accepted_without_the_option
    # default mode keeps handing patterns to Ruby's Regexp unchanged
    JSON::Validator.new(pattern_schema('(a)\1'))
    JSON::Validator.new(pattern_schema('[a&&b]'))
    JSON::Validator.new(pattern_schema('a*+'))
  end

  # patternProperties shares the same portable pattern handling.

  def test_pattern_properties
    schema = {
      'patternProperties' => { '^S_' => { 'type' => 'string' } },
    }

    assert_valid(schema, { 'S_a' => 'ok' }, PORTABLE)
    refute_valid(schema, { 'S_a' => 1 }, PORTABLE)
    # keys that do not match the pattern are not constrained by its schema
    assert_valid(schema, { 'xS_a' => 1 }, PORTABLE)
  end

  def test_pattern_properties_anchors_are_string_anchors
    schema = {
      'patternProperties' => { '^a$' => {} },
      'additionalProperties' => false,
    }

    # "a\nb" does not match ^a$ in ECMAScript, so it is an additional property
    refute_valid(schema, { "a\nb" => 1 }, PORTABLE)
    assert_valid(schema, { 'a' => 1 }, PORTABLE)

    # Ruby's ^ and $ match at line boundaries, so the key matches by default
    assert_valid(schema, { "a\nb" => 1 })
  end

  def test_pattern_properties_with_no_additional_properties_option
    schema = {
      'properties' => { 'a' => {} },
      'patternProperties' => { '^x\d$' => {} },
    }

    assert_valid(schema, { 'a' => 1, 'x1' => 2 }, PORTABLE.merge(noAdditionalProperties: true))
    refute_valid(schema, { 'a' => 1, 'y1' => 2 }, PORTABLE.merge(noAdditionalProperties: true))
  end

  def test_pattern_properties_rejection_points_at_key_location
    schema = { 'patternProperties' => { 'x(?=y)' => {} } }

    assert_schema_error(schema, '#/patternProperties/x(?=y)')
  end

  def test_dependencies_are_not_mistaken_for_patterns
    # a property named "pattern" in a dependencies map is not a pattern
    JSON::Validator.new({ 'dependencies' => { 'pattern' => 'a(?=b)' } }, portable_patterns: true)

    # but patterns inside schema dependencies are checked
    schema = { 'dependencies' => { 'a' => { 'pattern' => 'a(?=b)' } } }

    assert_schema_error(schema, '#/dependencies/a/pattern')
  end

  # The compiler itself.

  def test_compile_returns_equivalent_regexp
    regexp = JSON::Util::PortablePattern.compile('^a{2,3}$')

    assert_instance_of(Regexp, regexp)
    assert_match(regexp, 'aa')
    refute_match(regexp, 'a')
  end

  def test_compile_caches_regexps
    JSON::Util::PortablePattern.clear_cache
    regexp = JSON::Util::PortablePattern.compile('abc')

    assert_same(regexp, JSON::Util::PortablePattern.compile('abc'))
  end

  def test_error_exposes_pattern_and_position
    error = assert_raises(JSON::Util::PortablePattern::Error) do
      JSON::Util::PortablePattern.compile('ab(?=c)')
    end

    assert_equal('ab(?=c)', error.pattern)
    assert_equal(2, error.position)
  end
end
