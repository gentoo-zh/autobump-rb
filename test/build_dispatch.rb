#!/usr/bin/env ruby
# frozen_string_literal: true
# Hermetic dispatch test for BuildTest#run. Run: ruby test/build_dispatch.rb
require_relative '../lib/autobump'

Context = Struct.new(:payload, :install, :smoke)

class DispatchProbe < Autobump::BuildTest
  attr_reader :calls

  def initialize(ctx)
    super
    @calls = []
  end

  private

  def prebuilt_gate = @calls << :prebuilt_gate
  def install_and_smoke = @calls << :install_and_smoke
end

$fail = 0
def check(name, payload:, install:, want:)
  probe = DispatchProbe.new(Context.new(payload, install))
  probe.run
  got = probe.calls
  if got == want
    puts "ok   #{name}"
  else
    $fail += 1
    puts "FAIL #{name}\n       got  #{got.inspect}\n       want #{want.inspect}"
  end
end

check 'payload with --install bypasses dependency-free gate', payload: true, install: true,
      want: [:install_and_smoke]
check 'payload without --install uses dependency-free gate', payload: true, install: false,
      want: [:prebuilt_gate]
check 'source with --install still emerges', payload: false, install: true,
      want: [:install_and_smoke]
check 'source without --install remains surface-diff only', payload: false, install: false,
      want: []

puts '----'
puts "build_dispatch: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
