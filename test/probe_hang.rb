#!/usr/bin/env ruby
# frozen_string_literal: true
# Test the version smoke and the GUI launch probe against a launcher that starts its app under
# setsid, as /usr/bin/reasonix-desktop starts Electron. The app keeps the probe's output open
# from outside the process group; reading that output to EOF hung the job for hours.
# Hermetic: the binaries are shell scripts and Xvfb is not started. Run: ruby test/probe_hang.rb
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

class Probe < Autobump::BuildTest
  def initialize(ctx, bins)
    super(ctx)
    @bins = bins
  end

  def bins(_pkg) = @bins
  def spawn(*) = Process.spawn('true') # no Xvfb; the launches never reach a display
end

Evidence = Struct.new(:files) do
  def write(name, text) = files[name] = text
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def gone?(pidfile)
  Process.kill(0, File.read(pidfile).to_i)
  false
rescue Errno::ESRCH
  true
end

Dir.mktmpdir('autobump-probe-') do |dir|
  pidfile = File.join(dir, 'pid')
  launcher = File.join(dir, 'launcher')
  File.write(launcher, <<~SH)
    #!/bin/sh
    escape() {
      setsid -f sh -c 'echo $$ > #{pidfile}; exec sleep 30'
      while [ ! -s #{pidfile} ]; do sleep 0.05; done
    }
    case "$*" in
    --version) echo "launcher 1.2.3"; escape ;;
    *--no-sandbox*) escape ;;
    *) echo 'Running as root without --no-sandbox is not supported.' >&2 ;;
    esac
    exit 0
  SH
  fast = File.join(dir, 'fast')
  File.write(fast, <<~SH)
    #!/bin/sh
    case "$1" in
    --version) printf 'banner\\nbanner\\nbanner\\nfast 1.2.3\\n' ;;
    version) echo "fast version 1.2.3"; echo "built 1.2.3" ;;
    esac
  SH
  File.chmod(0o755, launcher, fast)

  ctx = lambda do
    Autobump::Context.new(cfg: Struct.new(:sudo).new(''), pkg: 'app-misc/fixture', newver: '1.2.3',
                          smoke: '', evidence: Evidence.new({}))
  end

  c = ctx.call
  Probe.new(c, [fast]).send(:smoke_version)
  check 'version output past the third line is not read', c.smoke, 'version ok: fast: fast version 1.2.3'

  c = ctx.call
  t = now
  Probe.new(c, [launcher]).send(:smoke_version)
  check 'the version smoke does not wait on the escaped app', now - t < 10, true
  check 'and still reads the version', c.smoke, '--version ok: launcher: launcher 1.2.3'
  check 'the escaped app is gone after the version smoke', gone?(pidfile), true

  File.delete(pidfile)
  c = ctx.call
  t = now
  Probe.new(c, [launcher]).send(:gui_probe)
  check 'the GUI probe does not wait on the escaped app', now - t < 10, true
  check 'and classifies the launch as before',
        c.smoke, ' | GUI launch probe: launcher exited immediately (status 0) before the 15s timeout ' \
                 '(after --no-sandbox fallback)'
  check 'the escaped app is gone after the GUI probe', gone?(pidfile), true
end

puts '----'
puts $fail.zero? ? 'probe_hang: all passed' : "probe_hang: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
