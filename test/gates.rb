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

# emerge refusing for a USE change says the same thing every run: it is a maintainer's call
use_change = <<~OUT
  The following USE changes are necessary to proceed:
   (see "package.use" in the portage(5) man page for more details)
  # required by app-dicts/fcitx-pinyin-moegirl-20260812::gentoo-zh
  >=app-i18n/opencc-1.1.9 python
OUT
check 'a USE-change refusal is not a flake', Autobump::BuildTest.needs_use_change?(use_change), true
check 'a mirror timeout is', Autobump::BuildTest.needs_use_change?("Connection timed out\n"), false

# portage's save module writes "WARN: setup" and then the body; a container has no kernel
# sources, so linux-info warns this way for every package that inherits it
kernel_notice = <<~ELOG
  WARN: setup
  Unable to find kernel sources at /usr/src/linux
  Unable to check for the following kernel config options due
  to absence of any configured kernel sources or compiled
  config:
   - PID_NS - PID_NS is required for sandbox to work
   - GRKERNSEC - CONFIG_GRKERNSEC breaks sandbox (bug #613668)
  You're on your own to make sure they are set if needed.
ELOG
check 'a kernel-config notice is not a defect',
      Autobump::BuildTest.elog_is_a_defect?(kernel_notice), false
check 'a QA section next to it still is',
      Autobump::BuildTest.elog_is_a_defect?(kernel_notice + "QA: install\nQA Notice: file does not exist\n"),
      true
check 'an elog whose only warning is something else is a defect',
      Autobump::BuildTest.elog_is_a_defect?("WARN: postinst\nrun me to finish the install\n"), true
check 'an elog with no warning section at all is left to a human',
      Autobump::BuildTest.elog_is_a_defect?("LOG: postinst\nnothing to see\n"), true
# an INFO section alongside the notice must not be read as a warning of its own
check 'an info section does not turn the notice into a defect',
      Autobump::BuildTest.elog_is_a_defect?(kernel_notice + "LOG: postinst\nremember to restart\n"), false

puts '----'
puts $fail.zero? ? 'gates: all passed' : "gates: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
