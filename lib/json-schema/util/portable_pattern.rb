module JSON
  module Util
    # PortablePattern compiles a supported subset of ECMAScript (ECMA-262)
    # regular expressions -- the dialect JSON Schema mandates for the
    # `pattern` keyword and for `patternProperties` keys -- into Ruby Regexp
    # objects with equivalent matching semantics.
    #
    # Ruby's Regexp and ECMAScript's RegExp disagree on a number of
    # constructs (for example `^`/`$` are line anchors in Ruby but string
    # anchors in ECMAScript, Ruby's `.` matches U+2028/U+2029 while
    # ECMAScript's does not, and Ruby's `\s` only covers ASCII whitespace).
    # Passing a schema pattern straight to Regexp.new therefore changes its
    # meaning. This compiler parses the pattern instead of rewriting it with
    # global string substitutions, so character class contents and escaped
    # backslashes are never corrupted.
    #
    # Supported in this first version:
    #   - literal characters (including identity escapes such as `\A`,
    #     which ECMAScript treats as the literal letter `A`)
    #   - character classes, including negation, ranges and nested `[`
    #   - groups: capturing `(...)` and non-capturing `(?:...)`
    #   - quantifiers: `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` and their lazy
    #     forms
    #   - alternation `|`
    #   - escapes: `\d \D \w \W \s \S \b \B \n \r \t \f \v \0 \xHH \uHHHH`
    #     (including surrogate pairs)
    #   - the anchors `^` and `$` (compiled to the string anchors `\A`/`\z`,
    #     so multi-line input follows ECMAScript semantics)
    #
    # Explicitly not supported (rejected with JSON::Util::PortablePattern::Error):
    #   - lookaround: `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`
    #   - named groups and named backreferences: `(?<name>...)`, `\k<name>`
    #   - backreferences: `\1` .. `\9`
    #   - octal escapes: `\0` followed by a digit
    #   - control escapes: `\cX`
    #   - possessive or stacked quantifiers: `a*+`, `a{2}{3}`, ...
    #   - `\S` inside a character class (cannot be expanded equivalently)
    #   - lone UTF-16 surrogates, which cannot be represented in a Ruby
    #     UTF-8 pattern
    #
    # Patterns are always compiled for unanchored search, as JSON Schema
    # requires; nothing is implicitly anchored. Compilation never falls back
    # to Ruby's own interpretation: unsupported or invalid input raises
    # JSON::Util::PortablePattern::Error.
    class PortablePattern
      # Raised when a pattern uses syntax outside the supported subset or is
      # not a valid ECMAScript regular expression.
      class Error < StandardError
      end

      # Characters matched by ECMAScript `\s` (WhiteSpace + LineTerminator),
      # expressed as Ruby character class items.
      ECMA_WHITESPACE_ITEMS = "\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff".freeze
      ECMA_WHITESPACE_CLASS = "[#{ECMA_WHITESPACE_ITEMS}]".freeze
      ECMA_NOT_WHITESPACE_CLASS = "[^#{ECMA_WHITESPACE_ITEMS}]".freeze

      # ECMAScript `.` matches anything except line terminators.
      ECMA_DOT_CLASS = '[^\n\r\u{2028}\u{2029}]'.freeze

      @cache = {}
      @cache_mutex = Mutex.new

      class << self
        # Compile an ECMAScript pattern source string into an equivalent Ruby
        # Regexp. Raises PortablePattern::Error on unsupported or invalid
        # syntax. Results are memoized per source string.
        def compile(source)
          @cache_mutex.synchronize do
            cached = @cache[source]
            return cached if cached

            regexp = Regexp.new(Parser.new(source).parse)
            @cache[source] = regexp
            regexp
          end
        end
      end

      # Recursive descent parser for the supported ECMAScript subset. Emits
      # an equivalent Ruby regexp source string.
      class Parser
        HEX_DIGIT = /\A[0-9a-fA-F]\z/.freeze
        DECIMAL_DIGIT = /\A[0-9]\z/.freeze

        def initialize(source)
          @source = source.to_s
          @length = @source.length
          @pos = 0
        end

        def parse
          out = parse_alternation
          error!('unmatched )') unless eof?

          out
        end

        private

        def peek(offset = 0)
          @source[@pos + offset]
        end

        def advance
          char = @source[@pos]
          @pos += 1
          char
        end

        def eof?
          @pos >= @length
        end

        def error!(message)
          raise Error, "#{message} (at offset #{@pos})"
        end

        def parse_alternation
          branches = [parse_sequence]
          while peek == '|'
            advance
            branches << parse_sequence
          end
          branches.join('|')
        end

        def parse_sequence
          out = ''
          out << parse_term until eof? || peek == '|' || peek == ')'
          out
        end

        def parse_term
          atom = parse_atom
          quantifier = parse_quantifier
          quantifier ? "#{atom}#{quantifier}" : atom
        end

        def parse_quantifier
          char = peek
          text =
            case char
            when '*', '+', '?'
              advance
              char
            when '{'
              parse_brace_quantifier
            end
          return nil unless text

          if peek == '?'
            advance
            text = "#{text}?"
          end

          # ECMAScript rejects a quantifier directly following another
          # quantifier; this also rules out Ruby-only possessive forms.
          error!('a quantifier cannot directly follow another quantifier') if quantifier_ahead?

          text
        end

        def quantifier_ahead?
          char = peek
          return false if char.nil?
          return true if ['*', '+', '?'].include?(char)

          return false unless char == '{'

          saved = @pos
          result = !brace_quantifier.nil?
          @pos = saved
          result
        end

        # Parses `{n}`, `{n,}` or `{n,m}` at the current position. Returns
        # nil (restoring the position) when the `{` does not start a valid
        # quantifier, in which case ECMAScript treats it as a literal.
        def parse_brace_quantifier
          saved = @pos
          text = brace_quantifier
          @pos = saved unless text
          text
        end

        def brace_quantifier
          return nil unless peek == '{'

          saved = @pos
          advance
          min = read_decimal_digits
          return nil unless min

          max = nil
          if peek == ','
            advance
            max = read_decimal_digits
          end
          return nil unless peek == '}'

          advance
          error!('numbers out of order in {} quantifier') if max && max.to_i < min.to_i

          @source[saved...@pos]
        end

        def read_decimal_digits
          digits = ''
          digits << advance while !eof? && peek.match?(DECIMAL_DIGIT)
          digits.empty? ? nil : digits
        end

        def parse_atom
          error!('unexpected end of pattern') if eof?

          char = advance
          case char
          when '^'
            '\A'
          when '$'
            '\z'
          when '.'
            ECMA_DOT_CLASS
          when '('
            parse_group
          when '['
            parse_class
          when '\\'
            parse_escape
          when '*', '+', '?'
            error!("nothing to repeat (#{char} cannot start an atom)")
          when '{'
            # A `{` that does not start a valid quantifier is a literal.
            '\{'
          when ']', '}'
            # Stray closers are literals in ECMAScript.
            "\\#{char}"
          else
            escape_literal(char)
          end
        end

        def parse_group
          if peek == '?'
            advance
            case peek
            when ':'
              advance
            when '=', '!'
              error!("lookahead groups '(?#{peek}...)' are not supported in portable patterns")
            when '<'
              error!("lookbehind and named groups '(?<...)' are not supported in portable patterns")
            else
              error!("group extension '(?#{peek}...)' is not supported in portable patterns")
            end
          end

          body = parse_alternation
          error!('unterminated group') if eof?

          advance # consume ')'
          "(?:#{body})"
        end

        def parse_escape
          error!('trailing \\ at end of pattern') if eof?

          char = advance
          case char
          when 'd', 'D', 'w', 'W', 'b', 'B'
            "\\#{char}"
          when 's'
            ECMA_WHITESPACE_CLASS
          when 'S'
            ECMA_NOT_WHITESPACE_CLASS
          when 'n' then '\n'
          when 'r' then '\r'
          when 't' then '\t'
          when 'f' then '\f'
          when 'v' then '\v'
          when '0'
            error!('octal escapes are not supported in portable patterns') if !eof? && peek.match?(DECIMAL_DIGIT)

            '\0'
          when '1', '2', '3', '4', '5', '6', '7', '8', '9'
            error!("backreferences (\\#{char}) are not supported in portable patterns")
          when 'c'
            error!('control escapes (\\cX) are not supported in portable patterns')
          when 'k'
            error!('named backreferences (\\k<name>) are not supported in portable patterns')
          when 'x'
            if (codepoint = read_hex_codepoint(2))
              emit_codepoint(codepoint)
            else
              # ECMAScript identity escape: \x without two hex digits is a
              # literal x.
              'x'
            end
          when 'u'
            if (codepoint = read_unicode_codepoint)
              emit_codepoint(codepoint)
            else
              # ECMAScript identity escape: \u without four hex digits is a
              # literal u.
              'u'
            end
          else
            # ECMAScript identity escape: any other escaped character stands
            # for the character itself (e.g. \A matches a literal "A").
            escape_literal(char)
          end
        end

        def parse_class
          negate = false
          if peek == '^'
            advance
            negate = true
          end

          if peek == ']'
            advance
            # ECMAScript: [] never matches, [^] matches any character.
            return negate ? '[\s\S]' : '(?!)'
          end

          items = ''
          loop do
            error!('unterminated character class') if eof?

            if peek == ']'
              advance
              break
            end
            items << parse_class_item
          end
          "[#{'^' if negate}#{items}]"
        end

        def parse_class_item
          emitted, char = parse_class_atom
          return emitted unless char

          if peek == '-' && peek(1) && peek(1) != ']'
            advance # consume '-'
            second_emitted, second_char = parse_class_atom
            if second_char
              error!('range out of order in character class') if second_char.ord < char.ord

              "#{emitted}-#{second_emitted}"
            else
              # e.g. [a-\d]: ECMAScript treats the dash as a literal.
              "#{emitted}\\-#{second_emitted}"
            end
          else
            emitted
          end
        end

        # Returns [emitted_text, char] where char is the single character the
        # item represents, or nil when the item is a character set escape
        # (which cannot take part in a range).
        def parse_class_atom
          char = advance
          if char == '\\'
            parse_class_escape
          elsif char == '-'
            ['\-', '-']
          else
            [escape_class_literal(char), char]
          end
        end

        def parse_class_escape
          error!('trailing \\ in character class') if eof?

          char = advance
          case char
          when 'd', 'D', 'w', 'W'
            ["\\#{char}", nil]
          when 's'
            [ECMA_WHITESPACE_ITEMS, nil]
          when 'S'
            error!('\S inside a character class is not supported in portable patterns')
          when 'b'
            ['\b', "\b"]
          when 'n' then ['\n', "\n"]
          when 'r' then ['\r', "\r"]
          when 't' then ['\t', "\t"]
          when 'f' then ['\f', "\f"]
          when 'v' then ['\v', "\v"]
          when '0'
            error!('octal escapes are not supported in portable patterns') if !eof? && peek.match?(DECIMAL_DIGIT)

            ['\0', "\0"]
          when '1', '2', '3', '4', '5', '6', '7', '8', '9'
            error!("backreferences (\\#{char}) are not supported in portable patterns")
          when 'c'
            error!('control escapes (\\cX) are not supported in portable patterns')
          when 'k'
            error!('named backreferences (\\k<name>) are not supported in portable patterns')
          when 'x'
            if (codepoint = read_hex_codepoint(2))
              [emit_codepoint(codepoint), codepoint.chr(Encoding::UTF_8)]
            else
              %w[x x]
            end
          when 'u'
            if (codepoint = read_unicode_codepoint)
              [emit_codepoint(codepoint), codepoint.chr(Encoding::UTF_8)]
            else
              %w[u u]
            end
          else
            [escape_class_literal(char), char]
          end
        end

        # Reads exactly `count` hex digits, returning their codepoint, or nil
        # (restoring the position) when there are not enough hex digits.
        def read_hex_codepoint(count)
          saved = @pos
          digits = ''
          digits << advance while digits.length < count && !eof? && peek.match?(HEX_DIGIT)
          if digits.length == count
            digits.to_i(16)
          else
            @pos = saved
            nil
          end
        end

        # Reads \uHHHH, combining UTF-16 surrogate pairs. Lone surrogates
        # cannot be represented in a Ruby UTF-8 pattern and are rejected.
        def read_unicode_codepoint
          codepoint = read_hex_codepoint(4)
          return nil unless codepoint

          if high_surrogate?(codepoint)
            if peek == '\\' && peek(1) == 'u'
              saved = @pos
              @pos += 2
              low = read_hex_codepoint(4)
              return 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00) if low && low_surrogate?(low)

              @pos = saved
            end
            error!('lone UTF-16 surrogate cannot be represented in a Ruby pattern')
          elsif low_surrogate?(codepoint)
            error!('lone UTF-16 surrogate cannot be represented in a Ruby pattern')
          end
          codepoint
        end

        def high_surrogate?(codepoint)
          codepoint.between?(0xD800, 0xDBFF)
        end

        def low_surrogate?(codepoint)
          codepoint.between?(0xDC00, 0xDFFF)
        end

        def emit_codepoint(codepoint)
          "\\u{#{codepoint.to_s(16)}}"
        end

        # Escapes a literal character for use outside a character class.
        def escape_literal(char)
          if char.match?(/[.\^$*+?()\[\]{}|\\]/)
            "\\#{char}"
          else
            char
          end
        end

        # Escapes a literal character for use inside a character class. `[`
        # and `&` must be escaped so Ruby does not reinterpret them as POSIX
        # classes or class intersection.
        def escape_class_literal(char)
          if char.match?(/[\]\[\\^&-]/)
            "\\#{char}"
          else
            char
          end
        end
      end
    end
  end
end
