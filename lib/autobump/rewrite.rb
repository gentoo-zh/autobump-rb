# frozen_string_literal: true
module Autobump
  # Pure opaque-token extraction and ebuild assignment rewriting. Both callers run
  # before a Manifest can fetch an artifact; test/rewrite.rb pins their safety rules.
  module Rewrite
    Result = Struct.new(:text, :old_value, :reason, :changed, keyword_init: true)
    VALIDATION_VALUE = '__autobump_rewrite_validation__'

    class << self
      # Extract capture group 1 of `regex` from the fetched document. A non-match, an
      # empty capture or a bad pattern are deliberately indistinguishable to the caller:
      # none of them is safe to rewrite with.
      def extract_value(document, regex:)
        raw = Regexp.new(regex).match(document)&.[](1)
        raw.is_a?(String) && !raw.empty? ? raw : nil
      rescue RegexpError, TypeError, ArgumentError
        nil
      end

      # ${PV} stands for the version being bumped to, so a package whose token is listed
      # per release can name the one it needs. In a regex the version is escaped: an
      # unescaped 2.10.0 would also match 2x10x0 and select a neighbouring record.
      def expand_url(text, newver) = text&.gsub('${PV}', newver)
      def expand_regex(text, newver) = text&.gsub('${PV}') { Regexp.escape(newver) }

      # Replaces one scalar shell assignment while retaining indentation, quote style,
      # trailing whitespace/comments, and the ebuild's original line ending. It refuses
      # ambiguity instead of selecting the first matching assignment.
      def rewrite_assignment(text, var, value)
        return refused("rewrite variable #{var} is not a valid shell variable") unless valid_var?(var)
        return refused("rewrite value for #{var} is not a single-line printable token") unless printable?(value)

        lines = text.lines
        targets = lines.each_index.select do |i|
          lines[i].match?(/\A[ \t]*#{Regexp.escape(var)}=/) &&
            !lines[i].match?(/\A[ \t]*#/)
        end
        return refused("rewrite variable #{var} appears zero times; expected exactly one single-line assignment") if targets.empty?
        if targets.length > 1
          return refused("rewrite variable #{var} appears #{targets.length} times; expected exactly one single-line assignment")
        end

        index = targets.first
        assignment = parse_assignment(lines[index], var)
        return refused("rewrite variable #{var} is not a single-line assignment") unless assignment

        old = assignment[:old_value]
        return Result.new(text: text, old_value: old, changed: false) if old == value

        lines[index] = assignment[:prefix] + encoded(value, assignment[:quote]) +
                       assignment[:tail] + assignment[:ending]
        Result.new(text: lines.join, old_value: old, changed: true)
      end

      private

      def valid_var?(var) = var.is_a?(String) && var.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      def printable?(value) = value.is_a?(String) && value.match?(/\A[[:graph:]]+\z/)
      def refused(reason) = Result.new(reason: reason, changed: false)

      def parse_assignment(line, var)
        ending = line[/\r?\n\z/] || ''
        body = line[0, line.length - ending.length]
        match = /\A(?<prefix>[ \t]*#{Regexp.escape(var)}=)(?<rhs>.*)\z/.match(body)
        return unless match

        tail = '(?<tail>(?:[ \t]+#[^\r\n]*|[ \t]*))'
        quoted = if (m = /\A"(?<value>(?:\\.|[^"\\])*)"#{tail}\z/.match(match[:rhs]))
                   { quote: :double, value: unescape_double(m[:value]), tail: m[:tail] }
                 elsif (m = /\A'(?<value>[^']*)'#{tail}\z/.match(match[:rhs]))
                   { quote: :single, value: m[:value], tail: m[:tail] }
                 elsif (m = /\A(?<value>(?:\\.|[^[:space:]#"'])*)#{tail}\z/.match(match[:rhs]))
                   { quote: :bare, value: unescape_bare(m[:value]), tail: m[:tail] }
                 end
        return unless quoted

        { prefix: match[:prefix], old_value: quoted[:value], quote: quoted[:quote],
          tail: quoted[:tail], ending: ending }
      end

      def unescape_double(value)
        value.gsub(/\\(["\\$`])/) { Regexp.last_match(1) }
      end

      def unescape_bare(value)
        value.gsub(/\\(.)/) { Regexp.last_match(1) }
      end

      def encoded(value, quote)
        case quote
        when :double
          "\"#{value.gsub(/["\\$`]/) { |char| "\\#{char}" }}\""
        when :single
          "'#{value.gsub("'", %q('"'"'))}'"
        else
          value.gsub(%r{[^A-Za-z0-9_@%+=:,./-]}) { |char| "\\#{char}" }
        end
      end
    end
  end
end
