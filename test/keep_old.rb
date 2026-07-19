#!/usr/bin/env ruby
# frozen_string_literal: true
# Test the --keep-old wiring: CLI.parse recognizes the flag, defaults it off, and threads
# it through to the Context struct. The actual behavior (finalize adds the new ebuild without
# dropping the old one) is proven by a real keep-old bump in the autobump-trial workflow / e2e.
# Hermetic -- no portage, no git. Run: ruby test/keep_old.rb
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

puts '----'
puts "keep_old: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
