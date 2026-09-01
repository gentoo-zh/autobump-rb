#!/usr/bin/env ruby
# frozen_string_literal: true
# Test BuildTest.gui_launch_outcome: GUI launch results stay advisory but never call a
# failed launch a successful headless start. Hermetic -- no portage, Xvfb, or processes.
# Run: ruby test/gui_probe.rb
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

F = Autobump::BuildTest.method(:gui_launch_outcome)

check 'exit 1 is a launch failure',
      F.call('/usr/bin/fails-one', 1, '', false),
      ['fails-one failed to launch headless (exit status 1)', true]
check 'exit 127 is a launch failure',
      F.call('/usr/bin/missing-command', 127, '', false),
      ['missing-command failed to launch headless (exit status 127)', true]
check 'timeout means alive after 15s',
      F.call('/usr/bin/stays-alive', 124, '', false),
      ['stays-alive ran 15s headless without crashing', false]
check 'exit 0 is an immediate exit, not a success',
      F.call('/usr/bin/short-lived', 0, '', false),
      ['short-lived exited immediately (status 0) before the 15s timeout', false]
check 'missing library wins over exit status and records fallback',
      F.call('/usr/bin/needs-lib', 1, 'error while loading shared libraries: libfoo.so: cannot open', true),
      ['needs-lib MISSING A LIBRARY at runtime - likely broken (after --no-sandbox fallback)', true]
check 'signal exit retains its signal number',
      F.call('/usr/bin/segfaults', 139, '', false),
      ['segfaults crashed on start (signal 11) - verify (could be headless GL)', true]

puts '----'
if $fail.zero?
  puts 'gui_probe: all passed'
else
  puts "gui_probe: #{$fail} failed"
  exit 1
end
