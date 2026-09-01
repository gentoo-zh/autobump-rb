#!/usr/bin/env ruby
# frozen_string_literal: true
# Distfiles.local_failure: which `ebuild manifest` failures are local and permanent, so the
# sweep hands them to a human instead of retrying a slow mirror that was never the problem.
# Hermetic -- no portage, no network. Run: ruby test/fetch_failure.rb  (also `rake`).
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

F = Autobump::Distfiles.method(:local_failure)

check 'an unreadable ebuild is local',
      F.call(" * ebuild.sh, line 681: /repo/cat/pkg/pkg-1.ebuild: Permission denied\n"),
      '* ebuild.sh, line 681: /repo/cat/pkg/pkg-1.ebuild: Permission denied'
check 'a failed source is local',
      F.call("something\n * error sourcing ebuild\n"), '* error sourcing ebuild'
check 'a full disk is local',
      F.call("cp: No space left on device\n"), 'cp: No space left on device'
check 'a missing helper is local',
      F.call("/usr/bin/ebuild: line 3: wget: command not found\n"),
      '/usr/bin/ebuild: line 3: wget: command not found'
check 'the last local line wins',
      F.call("first: Permission denied\nlater: No space left on device\n"),
      'later: No space left on device'
check 'a slow mirror is not local',
      F.call("!!! Couldn't download 'pkg-1.tar.gz'. Aborting.\nConnection timed out\n"), nil
check 'a 404 is not local either',
      F.call("ERROR 404: Not Found.\n!!! Couldn't download 'pkg-1.tar.gz'.\n"), nil
check 'empty output is not local', F.call(''), nil

puts '----'
puts "fetch_failure: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
