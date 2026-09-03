#!/usr/bin/env ruby
# frozen_string_literal: true
# Test the two gates that decide whether a bump may become a PR: the elog gate (an emerge that
# saved a qa/warn/error elog for THIS package fails the overlay's CI) and the pkgcheck gate (a
# finding the bump introduced). Hermetic. Run: ruby test/gates.rb
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

E = Autobump::BuildTest.method(:own_elog?)
LOG = '/var/tmp/plog/elog'

check 'the bumped package, flat layout',
      E.call("#{LOG}/dev-util/../app-editors:cursor-3.19.7:20260903-100000.log", 'app-editors', 'cursor', '3.19.7'), true
check 'the bumped package, split-elog layout',
      E.call("#{LOG}/app-editors/cursor-3.19.7:20260903-100000.log", 'app-editors', 'cursor', '3.19.7'), true
check "a dependency's own elog is not this bump's",
      E.call("#{LOG}/net-libs:nodejs-24.0.0:20260903-100000.log", 'app-editors', 'cursor', '3.19.7'), false
check 'a sibling sharing the pn prefix is not this bump',
      E.call("#{LOG}/dev-python:conda-libmamba-solver-1.0:20260903-100000.log", 'dev-python', 'conda', '1.0'), false
check 'a longer version sharing the prefix is not this bump',
      E.call("#{LOG}/app-editors:cursor-3.19.70:20260903-100000.log", 'app-editors', 'cursor', '3.19.7'), false

I = Autobump::Finalize.method(:introduced)

check 'an unchanged scan introduces nothing',
      I.call("DeadUrl: a\nUnstableOnly: b\n", "DeadUrl: a\nUnstableOnly: b\n"), ''
check 'a new finding is what the bump introduced',
      I.call("DeadUrl: a\n", "DeadUrl: a\nMissingRemoteId: c\n"), "MissingRemoteId: c\n"
check 'a finding the bump fixed is not a reason to escalate',
      I.call("DeadUrl: a\nUnstableOnly: b\n", "DeadUrl: a\n"), ''

puts '----'
puts $fail.zero? ? 'gates: all passed' : "gates: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
