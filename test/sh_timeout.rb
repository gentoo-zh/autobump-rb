#!/usr/bin/env ruby
# frozen_string_literal: true
# Test Context#sh: what it returns, and that a timeout takes the whole process group with it.
# `timeout` alone only kills the process it supervises, so an emerge that overran kept building
# as root while cleanup restored the checkout underneath it.
# Hermetic. Run: ruby test/sh_timeout.rb
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

ctx = Autobump::Context.new(cfg: Struct.new(:sudo).new(''))

out, ok, code = ctx.sh('bash', '-c', 'echo hi; exit 0')
check 'output, ok and code of a success', [out.strip, ok, code], ['hi', true, 0]

_, ok, code = ctx.sh('bash', '-c', 'echo to stderr >&2; exit 3')
check 'a failure keeps its exit code', [ok, code], [false, 3]

out, = ctx.sh('bash', '-c', 'echo to stderr >&2')
check 'stderr is part of the output', out.strip, 'to stderr'

out, ok, code = ctx.sh('no-such-command-in-this-test')
check 'a missing command degrades instead of raising', [ok, code], [false, 127]
check 'and says what happened', out.include?('no-such-command-in-this-test'), true

Dir.mktmpdir('autobump-sh-') do |dir|
  marker = File.join(dir, 'alive')
  _, ok, code = ctx.sh('bash', '-c', "(while true; do touch #{marker}; sleep 0.2; done) & sleep 30", timeout: 2)
  check 'a timeout is code 124', [ok, code], [false, 124]

  before = File.mtime(marker)
  sleep 2
  check 'the background child died with the group', File.mtime(marker), before
end

puts '----'
puts $fail.zero? ? 'sh_timeout: all passed' : "sh_timeout: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
