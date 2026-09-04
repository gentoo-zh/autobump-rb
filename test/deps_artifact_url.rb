#!/usr/bin/env ruby
# frozen_string_literal: true
# Hermetic: proves old-version URL rewriting cannot rewrite a newly-expanded ${PV} prefix.
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

F = Autobump::Classify.method(:deps_artifact_url)

check 'a target which extends the old version is expanded once',
      F.call('https://example.test/${PV}/go-tools-${PV}-vendor.tar.xz',
             pn: 'staticcheck', old_pv: '2026.2', newver: '2026.2.1'),
      'https://example.test/2026.2.1/go-tools-2026.2.1-vendor.tar.xz'

check 'a literal old version path is rewritten before variables expand',
      F.call('https://example.test/v1.2/pkg-1.2-vendor.tar.xz',
             pn: 'pkg', old_pv: '1.2', newver: '1.3'),
      'https://example.test/v1.3/pkg-1.3-vendor.tar.xz'

puts '----'
puts $fail.zero? ? 'deps_artifact_url: all passed' : "deps_artifact_url: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
