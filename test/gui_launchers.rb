#!/usr/bin/env ruby
# frozen_string_literal: true
# Test which files the GUI launch probe starts, and what it reports for each kind of launch.
# chatgpt-desktop's probe ran node_modules/.bin scripts and playwright-core's browser
# reinstall scripts because it started every */bin/* file the package owns.
# Hermetic: the launchers are shell scripts and Xvfb is not started. Run: ruby test/gui_launchers.rb
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

class Probe < Autobump::BuildTest
  def initialize(ctx, files)
    super(ctx)
    @files = files
  end

  def owned_files(_pkg) = @files
  def gui_timeout = 1
  def spawn(*) = Process.spawn('true') # no Xvfb; the launches never reach a display
end

Evidence = Struct.new(:files) do
  def write(name, text) = files[name] = text
end

L = Autobump::BuildTest.method(:launchers)
X = Autobump::BuildTest.method(:desktop_exec)

check 'Exec= with field codes', X.call("[Desktop Entry]\nName=App\nExec=/opt/app/app %U\n"), '/opt/app/app'
check 'Exec= past an env prefix', X.call("[Desktop Entry]\nExec=env A=1 B=2 app --flag\n"), 'app'
check 'Exec= of an action is not the entry', X.call("[Desktop Action new]\nExec=other\n[Desktop Entry]\nExec=app\n"), 'app'
check 'no Exec=', X.call("[Desktop Entry]\nName=App\n"), nil

Dir.mktmpdir('autobump-launchers-') do |dir|
  ran = File.join(dir, 'ran')
  app = File.join(dir, 'opt/app/app')
  script = File.join(dir, 'opt/app/resources/node_modules/semver/bin/semver.js')
  desktop = File.join(dir, 'usr/share/applications/app.desktop')
  stray = File.join(dir, 'usr/share/applications/stray.desktop')
  [app, script, desktop].each { |f| FileUtils.mkdir_p(File.dirname(f)) }
  File.write(desktop, "[Desktop Entry]\nType=Application\nExec=\"#{app}\" %U\n")
  File.write(stray, "[Desktop Entry]\nExec=/usr/bin/xdg-open\n")
  File.write(script, "#!/bin/sh\ntouch #{ran}\n")
  File.chmod(0o755, script)

  files = ['/usr/bin/app', '/usr/sbin/appd', '/opt/bin/app-cli', '/opt/app/resources/cua_node/bin/node',
           '/opt/app/resources/cua_node/lib/node_modules/playwright-core/bin/reinstall_msedge_stable_linux.sh',
           script, app, desktop, stray]
  check 'launchers are what is on PATH and what the package\'s own .desktop entries run',
        L.call(files), ['/usr/bin/app', '/usr/sbin/appd', '/opt/bin/app-cli', app]

  probe = lambda do |body|
    File.write(app, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, app)
    c = Autobump::Context.new(cfg: Struct.new(:sudo).new(''), pkg: 'app-misc/fixture', smoke: '',
                              evidence: Evidence.new({}))
    Probe.new(c, [script, app, desktop]).send(:gui_probe)
    c.smoke.delete_prefix(' | GUI launch probe: ')
  end

  check 'an app that stays up', probe.call('exec sleep 30'), 'app ran 15s headless without crashing'
  check 'an app that crashes', probe.call('kill -SEGV $$'),
        'app crashed on start (signal 11) - verify (could be headless GL)'
  check 'an app that misses a library',
        probe.call("echo 'app: error while loading shared libraries: libnspr4.so: cannot open' >&2; exit 127"),
        'app MISSING A LIBRARY at runtime - likely broken'

  check 'the node_modules script never ran', File.exist?(ran), false

  pidfile = File.join(dir, 'pid')
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  check 'an app a wrapper starts under setsid',
        probe.call("setsid -f sh -c 'echo $$ > #{pidfile}; exec sleep 30'\n" \
                   "while [ ! -s #{pidfile} ]; do sleep 0.05; done"),
        'app exited immediately (status 0) before the 15s timeout'
  check 'returns without waiting on it', Process.clock_gettime(Process::CLOCK_MONOTONIC) - t < 10, true
  gone = begin
    Process.kill(0, File.read(pidfile).to_i)
    false
  rescue Errno::ESRCH
    true
  rescue Errno::ENOENT
    :never_started
  end
  check 'and leaves it not running', gone, true
end

puts '----'
puts $fail.zero? ? 'gui_launchers: all passed' : "gui_launchers: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
