# frozen_string_literal: true

require 'json-schema/errors/schema_error'

module JSON
  module Util
    # Translates the ECMAScript (ECMA-262) regular expression subset used by
    # JSON Schema `pattern` and `patternProperties` into equivalent Ruby
    # regexps.
    #
    # JSON Schema defines patterns as ECMAScript regular expressions, but this
    # library validates with Ruby's Regexp engine, whose syntax and semantics
    # differ in a number of places: `^` and `$` anchor to lines instead of the
    # whole string, `.` also matches "\r" and U+2028/U+2029, `\s` does not
    # cover Unicode whitespace, and escapes that are plain "identity escapes"
    # in ECMAScript (`\A`, `\e`, `\p`, `\z`, ...) have special meanings in
    # Ruby. Handing schema patterns straight to `Regexp.new` therefore
    # silently changes their meaning.
    #
    # PortablePattern performs a lexical analysis of the pattern (never a
    # global string substitution, so character class contents and escaped
    # backslashes are not corrupted) and compiles the supported ECMAScript
    # subset to a Ruby regexp with equivalent semantics:
    #
    # * literals (including Unicode characters) and `.`
    # * character classes, ranges and negation
    # * groups `(...)` and `(?:...)`
    # * quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` and lazy variants
    # * alternation `|`
    # * anchors `^` and `$` (whole-string, as in ECMAScript without /m)
    # * escapes: `\d \D \w \W \s \S \b \B \f \n \r \t \v \0 \xhh \uhhhh \cX`,
    #   escaped syntax characters, and ECMAScript identity escapes (any other
    #   escaped character stands for itself)
    #
    # Constructs whose meaning cannot be reproduced faithfully are rejected
    # with a PortablePattern::Error instead of silently falling back to Ruby
    # semantics:
    #
    # * backreferences (`\1`, ...) and named backreferences (`\k<name>`)
    # * legacy octal escapes (`\07`, ...)
    # * lookaround assertions `(?=`, `(?!`, `(?<=`, `(?<!`
    # * named capture groups `(?<name>...)` and other `(?...)` constructs
    # * lone UTF-16 surrogate escapes (`\uD800` - `\uDFFF`)
    # * quantified assertions (`^*`, `\b+`, ...)
    # * stacked quantifiers (`a*+`, `a??+`, ...), which Ruby would read as
    #   possessive quantifiers
    # * Ruby-specific class constructs that mean something else in
    #   ECMAScript: POSIX classes (`[[:alpha:]]`) and class intersection
    #   (`[a&&b]`)
    # * malformed patterns (unterminated group or class, `{n,m}` with n > m,
    #   trailing backslash, ...)
    #
    # Declared semantics:
    #
    # * Matching is always an unanchored search, like ECMAScript
    #   `RegExp.prototype.test` and Ruby `Regexp#match`.
    # * Patterns operate on Unicode characters (code points). ECMAScript
    #   matches UTF-16 code units; for characters outside the Basic
    #   Multilingual Plane the two views differ, and portable patterns use
    #   the code point view. Lone surrogates cannot be represented as Ruby
    #   characters and are rejected.
    # * `.` excludes the four ECMAScript line terminators (\n, \r, U+2028,
    #   U+2029), so multi-line input behaves as in ECMAScript without /s.
    # * `^` and `$` only match at the start and end of the whole string, as
    #   in ECMAScript without /m.
    module PortablePattern
      # Raised when a pattern is not part of the supported ECMAScript subset
      # or is malformed. Carries the offending pattern and the character
      # offset at which the problem was detected.
      class Error < JSON::Schema::SchemaError
        attr_reader :pattern, :position

        def initialize(pattern, position, detail)
          @pattern = pattern
          @position = position
          super("#{detail} (at offset #{position} of pattern #{pattern.inspect})")
        end
      end

      # ECMAScript WhiteSpace and LineTerminator characters, as Ruby
      # character class source.
      SPACE_CLASS = '\\t\\n\\v\\f\\r \\u{a0}\\u{1680}\\u{2000}-\\u{200a}\\u{2028}\\u{2029}\\u{202f}\\u{205f}\\u{3000}\\u{feff}'

      # `.` matches anything but the four ECMAScript line terminators.
      DOT_CLASS = '[^\\n\\r\\u{2028}\\u{2029}]'

      # `[^]` matches any single character in ECMAScript.
      ANY_CHAR_CLASS = '[\\s\\S]'

      # `[]` never matches in ECMAScript.
      NEVER_MATCH_CLASS = '(?!)'

      REGEXP_SYNTAX_CHARS = '^$.[]\\|*+?(){}'
      CLASS_SYNTAX_CHARS = '\\[]^-'
      DIGITS = '0123456789'
      HEX_DIGITS = '0123456789abcdefABCDEF'
      LETTERS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

      @cache = {}
      @cache_mutex = Mutex.new

      class << self
        # Compiles an ECMAScript pattern to an equivalent Ruby Regexp.
        #
        # Raises PortablePattern::Error for unsupported or malformed
        # patterns; never falls back to Ruby's own interpretation.
        def compile(pattern)
          raise TypeError, "portable pattern must be a String, got #{pattern.class}" unless pattern.is_a?(String)

          cached = @cache_mutex.synchronize { @cache[pattern] }
          return cached if cached

          regexp = Regexp.new(Parser.new(pattern).translate)
          @cache_mutex.synchronize { @cache[pattern] ||= regexp }
        end

        def clear_cache
          @cache_mutex.synchronize { @cache.clear }
        end
      end

      # Recursive descent lexer/parser for the supported ECMAScript subset.
      # Operates on characters (code points), tracking offsets so errors can
      # point at the offending position in the original pattern.
      class Parser
        def initialize(pattern)
          @pattern = pattern
          @chars = pattern.chars
          @pos = 0
          @out = +''
        end

        def translate
          sequence(top_level: true)
          @out
        end

        private

        def error(detail, position = @pos)
          raise Error.new(@pattern, position, detail)
        end

        def eof?
          @pos >= @chars.length
        end

        def peek(offset = 0)
          @chars[@pos + offset]
        end

        def advance
          char = @chars[@pos]
          @pos += 1
          char
        end

        def sequence(top_level:)
          until eof?
            char = peek
            if char == ')'
              break unless top_level

              error("unmatched ')'")
            elsif char == '|'
              advance
              @out << '|'
            else
              term
            end
          end
        end

        def term
          assertion = atom
          quantifier(assertion)
        end

        # Parses a single atom, appends its translation to @out and returns
        # whether the atom is a zero-width assertion.
        def atom
          char = peek
          case char
          when '^'
            advance
            @out << '\\A'
            true
          when '$'
            advance
            @out << '\\z'
            true
          when '.'
            advance
            @out << DOT_CLASS
            false
          when '('
            group
            false
          when '['
            character_class
            false
          when '\\'
            src, _literal, assertion = escape(in_class: false)
            @out << src
            assertion
          when '*', '+', '?'
            error("nothing to repeat for '#{char}'")
          when '{'
            if brace_quantifier
              error("nothing to repeat for '#{char}'")
            else
              @out << bare_literal(advance)
              false
            end
          else
            @out << bare_literal(advance)
            false
          end
        end

        def quantifier(assertion)
          quant =
            case peek
            when '*', '+', '?'
              advance
            when '{'
              brace_quantifier
            end
          return if quant.nil?

          error('cannot quantify an assertion') if assertion

          if peek == '?'
            advance
            quant = "#{quant}?"
          end

          error('stacked quantifiers are not supported') if quantifier_ahead?

          @out << quant
        end

        def quantifier_ahead?
          case peek
          when '*', '+', '?'
            true
          when '{'
            save = @pos
            ahead = !brace_quantifier.nil?
            @pos = save
            ahead
          else
            false
          end
        end

        # Reads `{n}`, `{n,}` or `{n,m}` at the current position and returns
        # its source, or nil (restoring the position) when the braces do not
        # form a quantifier, in which case ECMAScript treats them literally.
        def brace_quantifier
          save = @pos
          advance # consume '{'
          min = decimal_digits
          unless min
            @pos = save
            return nil
          end

          case peek
          when '}'
            advance
            "{#{min}}"
          when ','
            advance
            max = decimal_digits
            unless peek == '}'
              @pos = save
              return nil
            end
            advance
            error("quantifier range {#{min},#{max}} is out of order") if max && max.to_i < min.to_i

            max ? "{#{min},#{max}}" : "{#{min},}"
          else
            @pos = save
            nil
          end
        end

        def decimal_digits
          start = @pos
          advance while !eof? && DIGITS.include?(peek)
          (@pos > start) ? @chars[start...@pos].join : nil
        end

        def group
          start = @pos
          advance # consume '('
          if peek == '?'
            case peek(1)
            when ':'
              advance
              advance
              @out << '(?:'
            when '=', '!'
              error('lookahead assertions (?=...) and (?!...) are not supported', start)
            when '<'
              if ['=', '!'].include?(peek(2))
                error('lookbehind assertions (?<=...) and (?<!...) are not supported', start)
              else
                error('named capture groups (?<name>...) are not supported', start)
              end
            else
              error("unsupported group construct '(?#{peek(1)}'", start)
            end
          else
            @out << '('
          end

          sequence(top_level: false)
          error('unterminated group', start) if eof?

          advance # consume ')'
          @out << ')'
        end

        def character_class
          start = @pos
          advance # consume '['
          negated = false
          if peek == '^'
            negated = true
            advance
          end

          body = +''
          loop do
            error('unterminated character class', start) if eof?
            break if peek == ']'

            src, char = class_atom
            if peek == '-' && peek(1) != ']'
              advance # consume '-'
              error('unterminated character class', start) if eof?

              right_src, right_char = class_atom
              if char && right_char
                error("character range '#{char}-#{right_char}' is out of order", start) if char.ord > right_char.ord

                body << src << '-' << right_src
              else
                # ECMAScript treats '-' as a literal when either side of it
                # is a character class escape such as \d
                body << src << '\\-' << right_src
              end
            else
              body << src
            end
          end
          advance # consume ']'

          if body.empty?
            @out << (negated ? ANY_CHAR_CLASS : NEVER_MATCH_CLASS)
          else
            @out << '['
            @out << '^' if negated
            @out << body << ']'
          end
        end

        # Parses one character class item.
        # Returns [ruby_source, literal_char_or_nil].
        def class_atom
          char = peek
          case char
          when '\\'
            src, literal, = escape(in_class: true)
            [src, literal]
          when '['
            error('POSIX character classes ([[:...:]]) are not supported') if peek(1) == ':'

            advance
            ['\\[', '[']
          when '&'
            error('character class intersection (&&) is not supported') if peek(1) == '&'

            advance
            ['&', '&']
          else
            advance
            [class_literal(char), char]
          end
        end

        # Parses one escape sequence (the backslash is at the current
        # position). Returns [ruby_source, literal_char_or_nil, assertion].
        def escape(in_class:)
          start = @pos
          advance # consume '\'
          error('trailing backslash', start) if eof?

          char = advance
          case char
          when 'd', 'D', 'w', 'W', 's', 'S'
            [class_escape_source(char, in_class), nil, false]
          when 'b'
            # backspace inside a class, word boundary outside
            in_class ? literal_escape_result("\b", in_class) : ['\\b', nil, true]
          when 'B'
            # identity escape inside a class, non-word-boundary outside
            in_class ? literal_escape_result('B', in_class) : ['\\B', nil, true]
          when 'f'
            literal_escape_result("\f", in_class)
          when 'n'
            literal_escape_result("\n", in_class)
          when 'r'
            literal_escape_result("\r", in_class)
          when 't'
            literal_escape_result("\t", in_class)
          when 'v'
            literal_escape_result("\v", in_class)
          when '0'
            error('legacy octal escapes are not supported', start) if !eof? && DIGITS.include?(peek)

            literal_escape_result("\0", in_class)
          when '1', '2', '3', '4', '5', '6', '7', '8', '9'
            error("backreferences (\\#{char}) are not supported", start)
          when 'x'
            codepoint = fixed_hex(2)
            codepoint ? literal_escape_result(codepoint.chr(Encoding::UTF_8), in_class) : literal_escape_result('x', in_class)
          when 'u'
            codepoint = fixed_hex(4)
            if codepoint
              error('lone UTF-16 surrogate escapes are not supported', start) if (0xd800..0xdfff).cover?(codepoint)

              literal_escape_result(codepoint.chr(Encoding::UTF_8), in_class)
            else
              literal_escape_result('u', in_class)
            end
          when 'c'
            if !eof? && LETTERS.include?(peek)
              literal_escape_result((advance.ord % 32).chr, in_class)
            else
              literal_escape_result('c', in_class)
            end
          when 'k'
            error('named backreferences (\\k<name>) are not supported', start) if peek == '<'

            literal_escape_result('k', in_class)
          else
            # ECMAScript identity escape: any other escaped character stands
            # for itself, even where Ruby assigns a special meaning to the
            # same sequence (\A, \e, \p, \z, ...)
            literal_escape_result(char, in_class)
          end
        end

        def class_escape_source(char, in_class)
          case char
          when 'd' then in_class ? '0-9' : '[0-9]'
          when 'D' then in_class ? '\\D' : '[^0-9]'
          when 'w' then in_class ? 'A-Za-z0-9_' : '[A-Za-z0-9_]'
          when 'W' then in_class ? '\\W' : '[^A-Za-z0-9_]'
          when 's' then in_class ? SPACE_CLASS : "[#{SPACE_CLASS}]"
          when 'S' then "[^#{SPACE_CLASS}]"
          end
        end

        def literal_escape_result(char, in_class)
          if in_class
            [class_literal(char), char, false]
          else
            [bare_literal(char), char, false]
          end
        end

        def fixed_hex(count)
          return nil if @pos + count > @chars.length

          digits = @chars[@pos, count]
          return nil unless digits.all? { |digit| HEX_DIGITS.include?(digit) }

          @pos += count
          digits.join.to_i(16)
        end

        def bare_literal(char)
          ord = char.ord
          if ord < 0x20 || ord == 0x7f
            hex_literal(ord)
          elsif REGEXP_SYNTAX_CHARS.include?(char)
            "\\#{char}"
          else
            char
          end
        end

        def class_literal(char)
          ord = char.ord
          if ord < 0x20 || ord == 0x7f
            hex_literal(ord)
          elsif CLASS_SYNTAX_CHARS.include?(char)
            "\\#{char}"
          else
            char
          end
        end

        def hex_literal(ord)
          if ord <= 0xff
            format('\\x%02X', ord)
          else
            "\\u{#{ord.to_s(16)}}"
          end
        end
      end
    end
  end
end
