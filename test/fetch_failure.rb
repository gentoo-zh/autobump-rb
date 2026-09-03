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

MIRRORS = 'https://distfiles.gentoo.org/distfiles https://mirror.example/gentoo'

# portage probes the mirrors first, and a fresh distfile is never on them
mirror_then_timeout = <<~LOG
  >>> Downloading 'https://distfiles.gentoo.org/distfiles/23/pkg-1.0.tar.gz'
  2026-09-03 10:00:00 ERROR 404: Not Found.
  >>> Downloading 'https://upstream.example/pkg-1.0.tar.gz'
  Connecting to upstream.example|10.255.255.1|:443... failed: Connection timed out.
LOG
check 'a mirror 404 with a transient upstream is not a missing distfile',
      Autobump::Distfiles.upstream_missing?(mirror_then_timeout, MIRRORS), false

really_gone = <<~LOG
  >>> Downloading 'https://distfiles.gentoo.org/distfiles/23/pkg-2.0.tar.gz'
  2026-09-03 10:00:00 ERROR 404: Not Found.
  >>> Downloading 'https://upstream.example/pkg-2.0.tar.gz'
  2026-09-03 10:00:01 ERROR 404: Not Found.
LOG
check 'upstream answering 404 is a missing distfile',
      Autobump::Distfiles.upstream_missing?(really_gone, MIRRORS), true

forbidden = really_gone.sub('10:00:01 ERROR 404: Not Found.', '10:00:01 ERROR 403: Forbidden.')
check '403 counts as missing too', Autobump::Distfiles.upstream_missing?(forbidden, MIRRORS), true

check 'a log with no per-URI structure falls back to the whole text',
      Autobump::Distfiles.upstream_missing?("ERROR 404: Not Found.\n", MIRRORS), true

check 'an empty mirror list leaves every URI upstream',
      Autobump::Distfiles.upstream_missing?(mirror_then_timeout, ''), true

retried = <<~LOG
  >>> Downloading 'https://up.example/a.tar.xz'
  ERROR 404: Not Found.
  >>> Downloading 'https://up.example/a.tar.xz'
  2026-09-03 10:00:01 (1.00 MB/s) - 'a.tar.xz' saved [1/1]
  >>> Downloading 'https://up.example/b.tar.xz'
  Connection timed out.
LOG
check 'a URI portage came back to and fetched is not missing',
      Autobump::Distfiles.upstream_missing?(retried, MIRRORS), false

puts '----'
puts "fetch_failure: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
