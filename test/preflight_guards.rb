#!/usr/bin/env ruby
# frozen_string_literal: true
# Hermetic post-sync Preflight guard tests: local canonical repository only.
# Run: ruby test/preflight_guards.rb
require 'fileutils'
require 'stringio'
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

GIT_ENV = { 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
            'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' }.freeze

class MemoryEvidence
  def write(*) = nil
end

def git(*args)
  return if system(GIT_ENV, 'git', *args, out: File::NULL, err: File::NULL)

  raise "git #{args.join(' ')} failed"
end

def add_release(repo, version)
  pkgdir = File.join(repo, 'demo-cat/pkg')
  FileUtils.mkdir_p(pkgdir)
  File.write(File.join(pkgdir, "pkg-#{version}.ebuild"), "EAPI=8\n")
  git('-C', repo, 'add', '-A')
  git('-C', repo, 'commit', '-qm', version)
end

def preflight_result(initial:, synced:, target:)
  Dir.mktmpdir('autobump-preflight-') do |dir|
    canonical = File.join(dir, 'canonical')
    repo = File.join(dir, 'repo')
    FileUtils.mkdir_p(canonical)
    git('-C', canonical, 'init', '-q', '--initial-branch=master')
    FileUtils.mkdir_p(File.join(canonical, 'profiles'))
    File.write(File.join(canonical, 'profiles/repo_name'), "preflight-test\n")
    add_release(canonical, initial)
    git('clone', '-q', '--origin', 'canonical', canonical, repo)
    add_release(canonical, synced)

    pkgdir = File.join(repo, 'demo-cat/pkg')
    new_ebuild = File.join(pkgdir, "pkg-#{target}.ebuild")
    cfg = Autobump::Config.new(env: { 'AUTOBUMP_REPO' => repo, 'AUTOBUMP_SYNC_REMOTE' => 'canonical' })
    ctx = Autobump::Context.new(
      cfg: cfg, pkg: 'demo-cat/pkg', cat: 'demo-cat', pn: 'pkg', pkgdir: pkgdir, newver: target,
      old_ebuild: File.join(pkgdir, "pkg-#{initial}.ebuild"), old_pvr: initial, old_pv: initial,
      old_pvr_presync: initial, new_ebuild: new_ebuild, branch: "demo-cat-pkg-#{target}",
      evidence: MemoryEvidence.new, armed: false
    )
    out = $stdout
    $stdout = StringIO.new
    message = begin
      Autobump::Preflight.new(ctx).run
      nil
    rescue Autobump::Abort => e
      e.message
    ensure
      $stdout = out
    end
    [message, new_ebuild]
  end
end

# Baseline pkgcheck is outside these guards and would require portage tooling.
Autobump::Finalize.define_singleton_method(:pkgcheck_scan) { |_, _| '' }

message, = preflight_result(initial: '1.0.0', synced: '1.1.0', target: '1.1.0')
check 'already at target on synced master is refused', message, 'already at 1.1.0 on synced master'

message, new_ebuild = preflight_result(initial: '1.0.0', synced: '1.0.0-r1', target: '1.0.0-r1')
check 'an ebuild appearing on synced master is refused', message, "#{new_ebuild} already exists on synced master"

message, = preflight_result(initial: '1.0.0', synced: '2.0.0', target: '1.5.0')
check 'a target older than synced master is refused', message,
      'synced master is at 2.0.0, newer than target 1.5.0 (would downgrade)'

message, = preflight_result(initial: '1.0.0', synced: '1.1.0', target: '1.2.0')
check 'a genuinely newer target passes synced-master guards', message, nil

# cleanup removes the ebuild this run copied, and nothing else that happens to sit there
Dir.mktmpdir('autobump-cleanup-') do |repo|
  pkgdir = File.join(repo, 'demo-cat/pkg')
  FileUtils.mkdir_p(pkgdir)
  draft = File.join(pkgdir, 'pkg-2.0.ebuild')
  File.write(draft, "EAPI=8\n")
  git('-C', repo, 'init', '-q', '--initial-branch=master')

  cfg = Autobump::Config.new(env: { 'AUTOBUMP_REPO' => repo })
  ctx = Autobump::Context.new(cfg: cfg, pkg: 'demo-cat/pkg', pn: 'pkg', pkgdir: pkgdir,
                              new_ebuild: draft, copied_ebuild: false, evidence: MemoryEvidence.new)
  quiet = lambda do |&block|
    err = $stderr
    $stderr = StringIO.new
    begin
      block.call
    ensure
      $stderr = err
    end
  end
  system(*%w[git -C], repo, *%w[commit -q --allow-empty -m init], out: File::NULL, err: File::NULL)
  quiet.call { Autobump::Cleanup.run(ctx) }
  check "a draft this run did not create survives cleanup", File.exist?(draft), true

  ctx.copied_ebuild = true
  quiet.call { Autobump::Cleanup.run(ctx) }
  check 'the copy this run made is removed', File.exist?(draft), false
end

puts '----'
puts $fail.zero? ? 'preflight_guards: all passed' : "preflight_guards: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
