#!/usr/bin/env ruby
# frozen_string_literal: true
# Test version ordering. It decides whether a bump is a bump or a downgrade, and it must not
# depend on portage being installed: the engine's own CI is a plain runner without it.
# Hermetic. Run: ruby test/version_compare.rb
require 'fileutils'
require 'tmpdir'
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

V = Autobump::Version

# the pairs sort -V gets wrong, which is why this exists
check 'a release outranks its release candidate', V.newer?('1.2.3', '1.2.3_rc1'), true
check 'a release outranks its beta', V.newer?('1.1.0', '1.1.0_beta3'), true
check 'a release candidate does not outrank its release', V.newer?('1.2.3_rc1', '1.2.3'), false
check 'alpha is older than beta', V.compare('1.2_alpha', '1.2_beta'), -1
check 'rc2 is older than rc10', V.compare('1.2_rc2', '1.2_rc10'), -1
check 'a patch level outranks the release', V.newer?('2.0_p1', '2.0'), true

# PMS numeric rules
check '1.10 outranks 1.9', V.newer?('1.10', '1.9'), true
check 'a leading zero is a fraction', V.newer?('1.1', '1.02'), true
check 'a trailing letter outranks its release', V.newer?('1.0a', '1.0'), true
check 'a revision outranks the unrevised version', V.newer?('1.2.3-r1', '1.2.3'), true
check 'equal versions are equal', V.compare('1.2.3', '1.2.3'), 0
check 'a shorter version is older when the prefix matches', V.compare('1.2', '1.2.1'), -1

# release_ebuilds: what a bump copies from
Dir.mktmpdir('autobump-version-') do |repo|
  pkgdir = File.join(repo, 'demo-cat/pkg')
  FileUtils.mkdir_p(pkgdir)
  %w[pkg-1.2.3.ebuild pkg-1.2.3_rc1.ebuild pkg-9999.ebuild].each { |f| File.write(File.join(pkgdir, f), "EAPI=8\n") }
  system('git', '-C', repo, 'init', '-q')
  system('git', '-C', repo, 'add', '-A')
  system({ 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t', 'GIT_COMMITTER_NAME' => 't',
           'GIT_COMMITTER_EMAIL' => 't@t' }, 'git', '-C', repo, 'commit', '-qm', 'fixture')
  names = ->(paths) { paths.map { |p| File.basename(p) } }

  check 'the release sorts last, 9999 is not a release',
        names.call(V.release_ebuilds(repo, pkgdir)), %w[pkg-1.2.3_rc1.ebuild pkg-1.2.3.ebuild]

  File.write(File.join(pkgdir, 'pkg-1.9.0.ebuild'), "EAPI=8\n")
  check 'an untracked ebuild is not a bump base',
        names.call(V.release_ebuilds(repo, pkgdir)).last, 'pkg-1.2.3.ebuild'

  empty = File.join(repo, 'demo-cat/fresh')
  FileUtils.mkdir_p(empty)
  File.write(File.join(empty, 'fresh-1.0.ebuild'), "EAPI=8\n")
  check 'a package with nothing committed has no bump base', V.release_ebuilds(repo, empty), []
end

# git missing is not a crash: the filesystem is all there is
Dir.mktmpdir('autobump-version-nogit-') do |repo|
  pkgdir = File.join(repo, 'demo-cat/pkg')
  FileUtils.mkdir_p(pkgdir)
  File.write(File.join(pkgdir, 'pkg-1.0.ebuild'), "EAPI=8\n")
  path = ENV['PATH']
  ENV['PATH'] = '/nonexistent'
  begin
    check 'no git falls back to the filesystem',
          V.release_ebuilds(repo, pkgdir).map { |p| File.basename(p) }, %w[pkg-1.0.ebuild]
  ensure
    ENV['PATH'] = path
  end
end

puts '----'
puts $fail.zero? ? 'version_compare: all passed' : "version_compare: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
