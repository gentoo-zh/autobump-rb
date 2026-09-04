#!/usr/bin/env ruby
# frozen_string_literal: true
# Hermetic: a tag derived from PV is build provenance, not a stale source pin.
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

root = File.expand_path('..', __dir__)
Dir.mktmpdir('autobump-dynamic-pin') do |repo|
  pkgdir = File.join(repo, 'demo-cat', 'dynamicpin')
  FileUtils.mkdir_p(pkgdir)
  File.write(File.join(pkgdir, 'dynamicpin-1.0.0.ebuild'), <<~EBUILD)
    EAPI=8
    DESCRIPTION="dynamic build provenance tag"
    HOMEPAGE="https://example.test/dynamicpin"
    SRC_URI="https://example.test/dynamicpin-${PV}.tar.gz"
    LICENSE="MIT"
    SLOT="0"
    KEYWORDS="~amd64"

    src_compile() {
    	local -x GIT_TAG="v${PV}" GIT_REVISION="v${PV}"
    	:
    }
  EBUILD

  out, status = Open3.capture2e({ 'AUTOBUMP_REPO' => repo }, RbConfig.ruby,
                                 'bin/autobump', 'demo-cat/dynamicpin', '1.0.1', '--check', chdir: root)
  check 'a PV-derived source tag is mechanical', status.exitstatus, 0
  check 'a PV-derived source tag emits no escalation', out.include?('ESCALATE:'), false
end

puts '----'
puts $fail.zero? ? 'dynamic_source_pin: all passed' : "dynamic_source_pin: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
