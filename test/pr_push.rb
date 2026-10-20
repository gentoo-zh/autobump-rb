#!/usr/bin/env ruby
# frozen_string_literal: true
# Test what the PR stage (PR#run) sends to git and gh. A push GitHub failed on its side (pnpm
# 12.6.0 got "remote: Internal Server Error", cherry-studio-bin "fatal error in commit_refs")
# threw away a finished build, and a failed GUI launch was only a line in the smoke text that
# five reasonix-desktop bumps merged past.
# Hermetic: git and gh are shell scripts on PATH. Run: ruby test/pr_push.rb
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

class Stage < Autobump::PR
  def pauses = (@pauses ||= [])
  def pause(seconds) = pauses << seconds
end

Dir.mktmpdir('autobump-pr-') do |dir|
  bin = File.join(dir, 'bin')
  pushes = File.join(dir, 'pushes')
  creates = File.join(dir, 'creates')
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, 'git'), <<~SH)
    #!/bin/sh
    shift 2
    case "$1" in
    remote) echo git@github.com:bot/overlay.git ;;
    log) echo 'app-misc/fixture: add 1.2.3' ;;
    push)
      echo push >> #{pushes}
      if [ "$(wc -l < #{pushes})" -le "$FAKE_PUSH_FAILS" ]; then echo "$FAKE_PUSH_ERROR" >&2; exit 1; fi ;;
    esac
    exit 0
  SH
  File.write(File.join(bin, 'gh'), <<~SH)
    #!/bin/sh
    [ "$2" = create ] && echo "$*" >> #{creates}
    exit 0
  SH
  File.chmod(0o755, *Dir[File.join(bin, '*')])
  ENV['PATH'] = "#{bin}:#{ENV.fetch('PATH')}"

  run = lambda do |fails, error = '', gui_failures: nil, accepted_diffs: nil|
    [pushes, creates].each { |f| FileUtils.rm_f(f) }
    ENV['FAKE_PUSH_FAILS'] = fails.to_s
    ENV['FAKE_PUSH_ERROR'] = error
    cfg = Struct.new(:repo, :push_remote, :upstream_repo).new(dir, 'origin', 'gentoo-zh/overlay')
    c = Autobump::Context.new(cfg: cfg, pkg: 'app-misc/fixture', pr: true, branch: 'app-misc-fixture-1.2.3',
                              old_pvr: '1.2.2', newver: '1.2.3', smoke: 'installed',
                              evidence: Autobump::Evidence.new('fixture'), gui_failures: gui_failures,
                              accepted_diffs: accepted_diffs)
    stage = Stage.new(c)
    out = $stdout
    $stdout = StringIO.new
    raised = begin
      stage.run
      nil
    rescue Autobump::Abort, Autobump::Escalate => e
      e.class
    ensure
      $stdout = out
    end
    body = c.evidence.path('pr-body.md')
    { raised: raised, pushes: File.exist?(pushes) ? File.readlines(pushes).size : 0,
      creates: File.exist?(creates) ? File.readlines(creates) : [], pauses: stage.pauses,
      body: File.exist?(body) ? File.read(body) : '' }
  end

  r = run.call(2, 'remote: Internal Server Error')
  check 'two 5xx then success opens exactly one PR',
        r.values_at(:raised, :pushes, :pauses) + [r[:creates].size], [nil, 3, [5, 15], 1]
  r = run.call(1, "error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502\n" \
                  'fatal: the remote end hung up unexpectedly')
  check 'an HTTP 502 is retried', r.values_at(:raised, :pushes) + [r[:creates].size], [nil, 2, 1]
  r = run.call(1, ' ! [remote rejected] b -> b (fatal error in commit_refs)')
  check 'a failed commit_refs is retried', r.values_at(:raised, :pushes) + [r[:creates].size], [nil, 2, 1]
  r = run.call(9, 'remote: Internal Server Error')
  check 'three failures give up without a PR', r.values_at(:raised, :pushes, :creates),
        [Autobump::Abort, 3, []]

  r = run.call(1, ' ! [remote rejected] b -> b (refusing to allow a GitHub App to create or update ' \
                  'workflow `.github/workflows/x.yml` without `workflows` permission)')
  check 'the workflows refusal is not retried', r.values_at(:raised, :pushes, :pauses),
        [Autobump::Escalate, 1, []]
  r = run.call(1, ' ! [rejected] b -> b (non-fast-forward)')
  check 'a non-fast-forward is not retried', r.values_at(:raised, :pushes, :pauses), [Autobump::Abort, 1, []]
  r = run.call(1, 'remote: Permission to gentoo-zh/overlay.git denied to bot.')
  check 'an auth failure is not retried', r.values_at(:raised, :pushes, :pauses), [Autobump::Abort, 1, []]

  r = run.call(0, gui_failures: [['/usr/bin/reasonix-desktop',
                                  'reasonix-desktop failed to launch headless (exit status 1)']])
  check 'a failed GUI launch opens a draft', r[:creates].map { |l| l.include?('--draft') }, [true]
  check 'whose body names the launcher and the outcome',
        r[:body].include?("- `/usr/bin/reasonix-desktop`: reasonix-desktop failed to launch headless (exit status 1)"),
        true
  check 'and says why it is a draft', r[:body].include?('the GUI launch probe failed'), true
  r = run.call(0)
  check 'a clean probe does not', r[:creates].map { |l| l.include?('--draft') }, [false]
  check 'nor warns', r[:body].include?('GUI launch probe failed'), false

  r = run.call(0, accepted_diffs: ['payload removed paths accepted: usr/lib/fixture/libold.so'])
  check 'an accepted difference opens a draft', r[:creates].map { |l| l.include?('--draft') }, [true]
  check 'whose body lists it',
        r[:body].include?("so this PR is a draft — review them before merging\n" \
                          "- payload removed paths accepted: usr/lib/fixture/libold.so\n"), true
  r = run.call(0, accepted_diffs: [])
  check 'an empty list does not', r[:creates].map { |l| l.include?('--draft') }, [false]
  check 'nor lists anything', r[:body].include?('accepted these differences'), false
end

puts '----'
puts $fail.zero? ? 'pr_push: all passed' : "pr_push: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
