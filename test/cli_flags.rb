#!/usr/bin/env ruby
# frozen_string_literal: true
# Test what the command line asks the engine for: which flags parse, which combinations are
# refused, and which ebuilds --keep-old retires.
# Hermetic -- no portage, no git. Run: ruby test/cli_flags.rb
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

P = Autobump::CLI

# default off when the flag is absent
check 'default: keep_old false', P.parse(%w[dev-foo/bar 1.2.3])[:keep_old], false
# flag turns it on, order-independent (it is a --flag, not positional)
check '--keep-old -> true', P.parse(%w[--keep-old dev-foo/bar 1.2.3])[:keep_old], true
check 'flag after positionals', P.parse(%w[dev-foo/bar 1.2.3 --keep-old])[:keep_old], true
# recognized, not an "unknown arg" die: parse must add the flag BEFORE the else catch-all
# (an unknown token calls die -> exit 2), so parse returns a hash instead of exiting
check '--keep-old is a known flag', P.parse(%w[--keep-old 12345]).is_a?(Hash), true

# Context accepts keep_old: guards the keyword_init field declaration in runtime.rb. An
# undeclared field makes Context.new raise ArgumentError, which cli.rb silently downgrades
# to exit 2 -- masking the wiring bug -- so assert the round-trip explicitly.
ctx = Autobump::Context.new(pkg: 'dev-foo/bar', keep_old: true, armed: false)
check 'Context carries keep_old', ctx.keep_old, true
check 'Context keep_old nil when unset', Autobump::Context.new(pkg: 'x').keep_old, nil

# numeric form: keep the N most-recent versions (plain --keep-old stays true = keep all)
check '--keep-old=3 -> integer 3', P.parse(%w[--keep-old=3 dev-foo/bar 1.2.3])[:keep_old], 3
check '--keep-old=2 after positionals', P.parse(%w[dev-foo/bar 1.2.3 --keep-old=2])[:keep_old], 2
check '--keep-old=0 -> integer 0 (keep all)', P.parse(%w[--keep-old=0 dev-foo/bar 1.2.3])[:keep_old], 0
check 'plain --keep-old is true, not a number', P.parse(%w[--keep-old dev-foo/bar 1.2.3])[:keep_old], true
check 'Context carries integer keep_old', Autobump::Context.new(pkg: 'x', keep_old: 2).keep_old, 2

# sort_by_version orders ebuild paths oldest-first (basic case where sort -V and portage agree,
# so this passes with or without portage; the _rc/_pre prerelease ordering is verified on a
# Gentoo host where python-portage is present)
check 'sort_by_version oldest-first',
      Autobump::Finalize.sort_by_version(%w[/p/foo-2.0.ebuild /p/foo-1.1.ebuild /p/foo-1.0.ebuild], 'foo')
        .map { |p| File.basename(p) },
      %w[foo-1.0.ebuild foo-1.1.ebuild foo-2.0.ebuild]

# what the flag actually decides: which ebuilds the bump retires
F = Autobump::Finalize
paths = %w[/p/pkg-1.0.ebuild /p/pkg-1.2.0_rc1.ebuild /p/pkg-1.2.0.ebuild /p/pkg-1.1.0.ebuild]
sorted = F.sort_by_version(paths, 'pkg')
names = ->(list) { list.map { |f| File.basename(f) } }

check 'a release candidate sorts below its release, not above',
      names.call(sorted), %w[pkg-1.0.ebuild pkg-1.1.0.ebuild pkg-1.2.0_rc1.ebuild pkg-1.2.0.ebuild]
check 'keep 2 retires everything older',
      names.call(F.retire(sorted, 2, '/p/pkg-1.0.ebuild')), %w[pkg-1.0.ebuild pkg-1.1.0.ebuild]
check 'keep 9 retires nothing', F.retire(sorted, 9, '/p/pkg-1.0.ebuild'), []
check 'no keep_old retires the version the bump replaced',
      names.call(F.retire(sorted, false, '/p/pkg-1.0.ebuild')), %w[pkg-1.0.ebuild]
check 'keep_old true keeps every prior version', F.retire(sorted, true, '/p/pkg-1.0.ebuild'), []
check 'keep_old 0 keeps every prior version', F.retire(sorted, 0, '/p/pkg-1.0.ebuild'), []

# argument combinations that would report a bump nobody made
def refuses(args)
  Autobump::CLI.parse(args)
  false
rescue SystemExit
  true
end

check '--diff-only with --pr is refused', refuses(%w[--diff-only --pr cat/pkg 1.2.3]), true
check 'a second target version is refused', refuses(%w[cat/pkg 1.2.3 1.2.4]), true
check 'a second package is refused', refuses(%w[cat/one 1.2.3 cat/two]), true
check 'the ordinary invocation still parses',
      Autobump::CLI.parse(%w[cat/pkg 1.2.3 --pr]).values_at(:pkg, :newver, :pr), ['cat/pkg', '1.2.3', true]

puts '----'
puts "keep_old: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
