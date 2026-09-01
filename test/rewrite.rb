#!/usr/bin/env ruby
# frozen_string_literal: true
# Test opaque-token extraction, exact-one ebuild assignment rewrites, their CLI wiring,
# and Classify's pre-branch refusal. Hermetic: no network, Portage, or git.
# Run: ruby test/rewrite.rb
require 'tmpdir'
require_relative '../lib/autobump'

$fail = 0
def check(name, got, want)
  if got == want
    puts "ok   #{name}"
  else
    $fail += 1
    puts "FAIL #{name}\n       got  #{got.inspect}\n       want #{want.inspect}"
  end
end

def parse_exit(argv)
  Autobump::CLI.parse(argv)
  :returned
rescue SystemExit => e
  e.status
end

class MemoryEvidence
  def write(*) = nil
end

# Keep this call through Classify rather than testing only the shared parser: this is the
# pre-branch gate that must turn an ambiguous assignment into the engine's exit-3 path.
def classify_rewrite(text)
  Dir.mktmpdir('autobump-rewrite-test-') do |dir|
    ebuild = File.join(dir, 'pkg-1.0.ebuild')
    File.write(ebuild, text)
    Autobump::Classify.new(cfg: Object.new, pkg: 'cat/pkg', old_ebuild: ebuild,
                           old_pv: '1.0', newver: '1.1', evidence: MemoryEvidence.new,
                           rewrite_var: 'BUILD_ID').run.escalations
  end
end

R = Autobump::Rewrite
P = Autobump::CLI

# --- extraction -------------------------------------------------------------------------
check 'regex capture group 1 extracts',
      R.extract_value('prefix "version":"1.2.3" suffix', regex: '"version":"([\\d.]+)"'), '1.2.3'
check 'a field that is present extracts from compact JSON',
      R.extract_value('{"commitSha":"new-token"}', regex: '"commitSha":"([^"]+)"'), 'new-token'
check 'non-matching regex yields no value',
      R.extract_value('{"commitSha":"new-token"}', regex: '"version":"([\\d.]+)"'), nil
check 'empty capture yields no value',
      R.extract_value('{"commitSha":""}', regex: '"commitSha":"([^"]*)"'), nil
check 'a broken pattern yields no value instead of raising',
      R.extract_value('anything', regex: '([0-9]'), nil
check '${PV} in a url expands to the target version',
      R.expand_url('https://api.github.com/repos/o/r/releases/tags/${PV}', '2.1.2.3'),
      'https://api.github.com/repos/o/r/releases/tags/2.1.2.3'
check 'expanding an absent url stays absent', R.expand_url(nil, '1.0'), nil
check '${PV} in a regex is escaped so a dot cannot match anything',
      R.expand_regex('"version":"${PV}"', '2.10.0'), '"version":"2\\.10\\.0"'
doc = '{"version":"2x10x0","id":"wrong"},{"version":"2.10.0","id":"right"}'
check 'the escaped version selects the exact record',
      R.extract_value(doc, regex: R.expand_regex('"version":"${PV}","id":"([a-z]+)"', '2.10.0')),
      'right'
check 'an unescaped version would have matched the neighbour',
      R.extract_value(doc, regex: R.expand_url('"version":"${PV}","id":"([a-z]+)"', '2.10.0')),
      'wrong'

# --- exact-one line rewrite --------------------------------------------------------------
original = "  BUILD_ID=\"old-token\"  # source pin\nSRC_URI=\"https://example/${BUILD_ID}\"\n"
rewritten = R.rewrite_assignment(original, 'BUILD_ID', 'new-token')
check 'single assignment rewrites', rewritten.text,
      "  BUILD_ID=\"new-token\"  # source pin\nSRC_URI=\"https://example/${BUILD_ID}\"\n"
check 'single assignment records old value', rewritten.old_value, 'old-token'
check 'single assignment reports change', rewritten.changed, true

single_quoted = R.rewrite_assignment("MY_BUILD='old-token'\n", 'MY_BUILD', 'new-token')
check 'single assignment preserves single quotes', single_quoted.text, "MY_BUILD='new-token'\n"

same = R.rewrite_assignment(original, 'BUILD_ID', 'old-token')
check 'unchanged value leaves ebuild text alone', same.text, original
check 'unchanged value reports no rewrite', same.changed, false

check 'two assignments refuse',
      R.rewrite_assignment("BUILD_ID=\"one\"\nBUILD_ID=\"two\"\n", 'BUILD_ID', 'new').reason,
      'rewrite variable BUILD_ID appears 2 times; expected exactly one single-line assignment'
check 'zero assignments refuse',
      R.rewrite_assignment("SRC_URI=\"https://example\"\n", 'BUILD_ID', 'new').reason,
      'rewrite variable BUILD_ID appears zero times; expected exactly one single-line assignment'
check 'comment-only assignment refuses',
      R.rewrite_assignment("# BUILD_ID=\"old-token\"\n", 'BUILD_ID', 'new').reason,
      'rewrite variable BUILD_ID appears zero times; expected exactly one single-line assignment'
check 'multi-line assignment refuses',
      R.rewrite_assignment("BUILD_ID=\"old-token\ncontinued\"\n", 'BUILD_ID', 'new').reason,
      'rewrite variable BUILD_ID is not a single-line assignment'
check 'space-containing value refuses',
      R.rewrite_assignment("BUILD_ID=\"old-token\"\n", 'BUILD_ID', 'not safe').reason,
      'rewrite value for BUILD_ID is not a single-line printable token'

# This proves the actual Classify stage reuses the exact-one rule before preflight branches.
check 'Classify escalates duplicate rewrite variable',
      classify_rewrite("BUILD_ID=\"one\"\nBUILD_ID=\"two\"\n"),
      ['rewrite variable BUILD_ID appears 2 times; expected exactly one single-line assignment']

# --- interface validation ----------------------------------------------------------------
spec = P.parse(['--rewrite-var', 'MY_COMMIT', '--rewrite-url', 'https://cursor.com/api/download',
                '--rewrite-regex', '"commitSha":"([0-9a-f]{40})"', 'cat/pkg', '1.2.3'])
check 'CLI parses rewrite variable', spec[:rewrite_var], 'MY_COMMIT'
check 'CLI parses rewrite URL', spec[:rewrite_url], 'https://cursor.com/api/download'
check 'CLI parses the regex extractor', spec[:rewrite_regex], '"commitSha":"([0-9a-f]{40})"'
regex_spec = P.parse(['--rewrite-var', 'MY_BUILD', '--rewrite-url', 'https://example.test',
                      '--rewrite-regex', '"version":"([\\d.]+)"', 'cat/pkg', '1.2.3'])
check 'CLI parses regex extractor', regex_spec[:rewrite_regex], '"version":"([\\d.]+)"'
check 'CLI carries rewrite fields in Context',
      Autobump::Context.new(rewrite_var: 'MY_COMMIT', rewrite_url: 'https://example.test',
                            rewrite_regex: '(.+)').rewrite_regex,
      '(.+)'
check 'CLI rejects variable without URL through usage exit',
      parse_exit(%w[--rewrite-var MY_COMMIT --rewrite-regex (.+) cat/pkg 1.2.3]), 2
check 'CLI rejects variable without extractor through usage exit',
      parse_exit(%w[--rewrite-var BUILD_ID --rewrite-url https://example.test cat/pkg 1.2.3]), 2
check 'CLI rejects an invalid regex through usage exit',
      parse_exit(%w[--rewrite-var MY_COMMIT --rewrite-url https://example.test --rewrite-regex ([0-9] cat/pkg 1.2.3]), 2
check 'CLI rejects a regex with no capture group',
      parse_exit(%w[--rewrite-var MY_COMMIT --rewrite-url https://example.test --rewrite-regex commitSha cat/pkg 1.2.3]), 2

check 'CLI rejects a non-http rewrite URL',
      parse_exit(%w[--rewrite-var MY_COMMIT --rewrite-url file:///etc/passwd --rewrite-regex (.+) cat/pkg 1.2.3]), 2



# --- classify: a pin the rewrite updates is not a stale pin ------------------------------
require 'tmpdir'
def classify_notes(text, rewrite_var)
  Dir.mktmpdir do |dir|
    eb = File.join(dir, 'demo-1.0.ebuild')
    File.write(eb, text)
    ev = Autobump::Evidence.new(dir)
    Autobump::Classify.new(cfg: nil, pkg: 'demo-cat/demo', old_ebuild: eb, old_pv: '1.0',
                           newver: '1.1', evidence: ev, rewrite_var: rewrite_var).run.escalations
  end
end

pinned_ebuild = %(MY_COMMIT="deadbeef"\nSRC_URI="https://example/${MY_COMMIT}/x.tar.gz"\n)
check 'a pin with no rewrite spec still escalates',
      classify_notes(pinned_ebuild, nil).any? { |n| n.include?('pins a source commit/tag') }, true
check 'the pin the rewrite updates does not escalate',
      classify_notes(pinned_ebuild, 'MY_COMMIT').any? { |n| n.include?('pins a source commit/tag') }, false
check 'another unhandled pin still escalates',
      classify_notes(pinned_ebuild + %(OTHER_COMMIT="cafe"\n), 'MY_COMMIT')
        .any? { |n| n.include?('pins a source commit/tag') }, true

puts '----'
if $fail.zero?
  puts 'rewrite: all passed'
else
  puts "rewrite: #{$fail} failed"
  exit 1
end