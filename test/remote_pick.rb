#!/usr/bin/env ruby
# frozen_string_literal: true
# Test which remote master is synced from. Syncing from a mirror defeats the guard that the
# bump is built on canonical master. Hermetic. Run: ruby test/remote_pick.rb
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

R = Autobump::Config.method(:remote_named)

with_mirror = <<~OUT
  mirror\thttps://github.com/gentoo-zh/overlay-mirror.git (fetch)
  mirror\thttps://github.com/gentoo-zh/overlay-mirror.git (push)
  origin\tgit@github.com:Zakkaus/gentoo-zh.git (fetch)
  upstream\tgit@github.com:gentoo-zh/overlay.git (fetch)
OUT
check 'a mirror is not the canonical repo', R.call(with_mirror, 'gentoo-zh/overlay'), 'upstream'
check 'ssh and https forms both resolve',
      R.call("canonical\thttps://github.com/gentoo-zh/overlay (fetch)\n", 'gentoo-zh/overlay'), 'canonical'
check 'a push-only line is not a fetch remote',
      R.call("x\tgit@github.com:gentoo-zh/overlay.git (push)\n", 'gentoo-zh/overlay'), nil
check 'no match means no remote', R.call(with_mirror, 'gentoo/gentoo'), nil

puts '----'
puts $fail.zero? ? 'remote_pick: all passed' : "remote_pick: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
