#!/usr/bin/env ruby
# frozen_string_literal: true
# Hermetic: a pin the package names with --static-pin stays the same across versions, so it is
# not a stale source pin; every pin it does not name still escalates.
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

$fail = 0
def check(name, got, want)
  if got == want
    puts "ok   #{name}"
  else
    $fail += 1
    puts "FAIL #{name}\n       got  #{got.inspect}\n       want #{want.inspect}"
  end
end

PIN_NOTE = 'pins a source commit/tag'
root = File.expand_path('..', __dir__)
Dir.mktmpdir('autobump-static-pin') do |repo|
  write = lambda do |pn, pins|
    pkgdir = File.join(repo, 'demo-cat', pn)
    FileUtils.mkdir_p(pkgdir)
    File.write(File.join(pkgdir, "#{pn}-1.0.0.ebuild"), <<~EBUILD)
      EAPI=8
      #{pins}
      DESCRIPTION="icon fetched at a fixed commit"
      HOMEPAGE="https://example.test/#{pn}"
      SRC_URI="
      	https://example.test/icon.png?id=${ICON_COMMIT} -> ${P}.png
      	https://example.test/#{pn}-${PV}.tar.gz
      "
      LICENSE="MIT"
      SLOT="0"
      KEYWORDS="~amd64"
    EBUILD
  end
  write.('iconpin', 'ICON_COMMIT="8182e2d354c6b096e544f24b3ea8fcfb5e73d699"')
  write.('twopins', %(ICON_COMMIT="8182e2d354c6b096e544f24b3ea8fcfb5e73d699"\nSRC_COMMIT="deadbeef"))
  write.('oneline', 'ICON_COMMIT="8182e2d354c6b096e544f24b3ea8fcfb5e73d699" SRC_COMMIT="deadbeef"')

  run = lambda do |pkg, *flags|
    Open3.capture2e({ 'AUTOBUMP_REPO' => repo }, RbConfig.ruby,
                    'bin/autobump', pkg, '1.0.1', '--check', *flags, chdir: root)
  end

  out, status = run.('demo-cat/iconpin')
  check 'an unlisted pin escalates', status.exitstatus, 3
  check 'an unlisted pin names the stale pin', out.include?(PIN_NOTE), true

  out, status = run.('demo-cat/iconpin', '--static-pin', 'ICON_COMMIT')
  check 'a listed static pin is mechanical', status.exitstatus, 0
  check 'a listed static pin emits no escalation', out.include?('ESCALATE:'), false

  out, status = run.('demo-cat/twopins', '--static-pin', 'ICON_COMMIT')
  check 'a pin the list does not name still escalates', status.exitstatus, 3
  check 'the remaining pin names the stale pin', out.include?(PIN_NOTE), true

  out, status = run.('demo-cat/oneline', '--static-pin', 'ICON_COMMIT')
  check 'a second pin on the listed line still escalates', status.exitstatus, 3
  check 'the second pin on the line names the stale pin', out.include?(PIN_NOTE), true

  _, status = run.('demo-cat/iconpin', '--static-pin', 'ICON-COMMIT')
  check '--static-pin refuses a name that is not a shell variable', status.exitstatus, 2
end

puts '----'
puts $fail.zero? ? 'static_pins: all passed' : "static_pins: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
