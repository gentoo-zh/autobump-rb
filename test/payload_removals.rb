#!/usr/bin/env ruby
# frozen_string_literal: true
# Test which structural payload removals wait for the build and which still escalate. Last
# month sixteen "payload layout changed" escalations were pure renames (kiro, openchamber,
# claude-desktop, cursor ...); the rules below let those through only when nothing can still
# need the removed file, and every class of real break a reviewer listed stays escalated.
# Hermetic: the trees are temp directories, scanelf is a stub on PATH, nothing is emerged.
# Run: ruby test/payload_removals.rb
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

AD = Autobump::ArtifactDiff
BT = Autobump::BuildTest

# An Electron app directory as the new tree ships it: the binary, its markers and helpers.
ELECTRON_TREE = %w[
  opt/app/app opt/app/chrome-sandbox opt/app/chrome_crashpad_handler opt/app/resources.pak
  opt/app/icudtl.dat opt/app/libffmpeg.so opt/app/resources/app.asar
  usr/share/applications/app.desktop
].freeze
NEEDED = {
  'opt/app/app' => %w[libffmpeg.so libgtk-3.so.0 libc.so.6],
  'opt/app/chrome-sandbox' => %w[libc.so.6],
  'opt/app/libffmpeg.so' => %w[libc.so.6]
}.freeze
EBUILD = <<~EB
  QA_PREBUILT="*"
  src_install() {
  	insinto /opt/${PN}
  	doins -r opt/app/.
  	fperms 4711 /opt/${PN}/chrome-sandbox
  	dosym -r /opt/${PN}/app /usr/bin/app
  }
EB

def blockers(removed, old_exec: [], refs: { 'app-1.ebuild' => EBUILD }, text_hits: [],
             text_complete: true, needed: NEEDED, new_tree: ELECTRON_TREE)
  AD.removal_blockers(removed, new_tree: new_tree, old_exec: old_exec, refs: refs,
                                text_hits: text_hits, text_complete: text_complete, needed: needed)
end

def reasons(list) = list.map { |path, why| [path, why[/\A[^:]+/]] }

# --- accepted: the false escalations ------------------------------------------------------
# kiro: libEGL.so and libGLESv2.so left the Electron directory (mode 755, as Electron ships
# them) along with a changelog nothing reads
kiro = %w[opt/app/libEGL.so opt/app/libGLESv2.so opt/app/changelog.md]
check 'kiro: ANGLE libraries and a changelog nothing names wait for the build',
      blockers(kiro, old_exec: %w[opt/app/libEGL.so opt/app/libGLESv2.so]), []
check 'SwiftShader leaving the Electron directory waits for the build',
      blockers(%w[opt/app/libvk_swiftshader.so opt/app/vk_swiftshader_icd.json]), []

# openchamber: node-pty moved to the next Electron ABI directory, and ANGLE went away
pty = 'opt/app/resources/app.asar.unpacked/node_modules/node-pty/prebuilds'
rm, ad, ch = AD.fold_benign(%W[#{pty}/linux-x64-148/pty.node opt/app/libEGL.so opt/app/libGLESv2.so],
                            %W[#{pty}/linux-x64-149/pty.node], '2.3.3', '2.3.4')
check 'openchamber: a native module moved to the next ABI directory is a rename',
      [rm, ad, ch], [%w[opt/app/libEGL.so opt/app/libGLESv2.so], [], 2]
check 'openchamber: the ANGLE libraries left wait for the build', blockers(rm), []

# --- the ABI-directory rename stays narrow -------------------------------------------------
rm, = AD.fold_benign(%W[#{pty}/linux-x64-148/pty.node], %W[#{pty}/linux-arm64-148/pty.node], '1', '2')
check 'a native module moved to another platform directory is a removal', rm, %W[#{pty}/linux-x64-148/pty.node]
rm, = AD.fold_benign(%W[#{pty}/linux-x64-148/pty.node], %W[#{pty}/linux-x86-148/pty.node], '1', '2')
check 'a native module moved from x64 to x86 is a removal', rm, %W[#{pty}/linux-x64-148/pty.node]
rm, = AD.fold_benign(%W[#{pty}/linux-x64-148/pty.node], %W[#{pty}/linux-x64-149/other.node], '1', '2')
check 'a native module renamed with the move is a removal', rm, %W[#{pty}/linux-x64-148/pty.node]
rm, = AD.fold_benign(%w[lib/148/libfoo.so], %w[lib/149/libfoo.so], '1', '2')
check 'a shared object moved across numbered directories is a removal', rm, %w[lib/148/libfoo.so]

# --- escalated: what a removal can break -----------------------------------------------------
check 'a removed executable escalates',
      reasons(blockers(%w[opt/app/helper], old_exec: %w[opt/app/helper])),
      [['opt/app/helper', 'executable in the old tree']]
check 'a renamed chrome-sandbox escalates',
      reasons(blockers(%w[opt/app/chrome-sandbox-old], old_exec: %w[opt/app/chrome-sandbox-old])),
      [['opt/app/chrome-sandbox-old', 'executable in the old tree']]
check 'a removed shared object escalates even when it is not executable',
      reasons(blockers(%w[opt/app/libplugin.so opt/app/libvulkan.so.1 opt/app/native/addon.node])),
      [['opt/app/libplugin.so', 'a shared object or native module'],
       ['opt/app/libvulkan.so.1', 'a shared object or native module'],
       ['opt/app/native/addon.node', 'a shared object or native module']]
check 'a removed desktop entry escalates',
      reasons(blockers(%w[usr/share/applications/app-url-handler.desktop])),
      [['usr/share/applications/app-url-handler.desktop', 'a desktop entry or unit file']]
check 'a removed systemd unit escalates',
      reasons(blockers(%w[usr/lib/systemd/system/app.service])),
      [['usr/lib/systemd/system/app.service', 'a desktop entry or unit file']]

still_needed = NEEDED.merge('opt/app/app' => %w[libEGL.so libffmpeg.so libc.so.6])
check 'an ANGLE library the new binary still NEEDs escalates',
      blockers(%w[opt/app/libEGL.so], needed: still_needed),
      [['opt/app/libEGL.so', 'still NEEDED by opt/app/app']]
check 'an ANGLE library a NEEDED entry names by path escalates',
      blockers(%w[opt/app/libEGL.so], needed: NEEDED.merge('opt/app/app' => %w[/opt/app/libEGL.so libc.so.6])),
      [['opt/app/libEGL.so', 'still NEEDED by opt/app/app']]
check 'an ANGLE library some other object still NEEDs escalates',
      blockers(%w[opt/app/libGLESv2.so], needed: NEEDED.merge('opt/app/libffmpeg.so' => %w[libGLESv2.so])),
      [['opt/app/libGLESv2.so', 'still NEEDED by opt/app/libffmpeg.so']]
check 'an ANGLE library escalates when NEEDED cannot be read',
      reasons(blockers(%w[opt/app/libEGL.so], needed: nil)),
      [['opt/app/libEGL.so', 'NEEDED of the new tree unknown (scanelf failed)']]
check 'an ANGLE library outside an Electron directory escalates',
      reasons(blockers(%w[opt/app/gl/libEGL.so])),
      [['opt/app/gl/libEGL.so', 'not beside an Electron binary in the new tree']]
check 'an ANGLE library with no binary left beside it escalates',
      reasons(blockers(%w[opt/app/libEGL.so], needed: NEEDED.reject { |f, _| f == 'opt/app/app' })),
      [['opt/app/libEGL.so', 'no Electron binary beside it in the new tree']]

check 'a removed path the ebuild names escalates, with the line',
      blockers(%w[opt/app/resources/app-update.yml],
               refs: { 'app-1.ebuild' => EBUILD + "\trm opt/app/resources/app-update.yml || die\n" }),
      [['opt/app/resources/app-update.yml', 'app-1.ebuild names it: rm opt/app/resources/app-update.yml || die']]
check 'a removed path a files/ wrapper names escalates',
      reasons(blockers(%w[opt/app/resources/app.asar],
                       refs: { 'app-1.ebuild' => EBUILD,
                               'files/app.sh' => "#!/bin/sh\nexec electron /opt/app/resources/app.asar \"$@\"\n" })),
      [['opt/app/resources/app.asar', 'files/app.sh names it']]
check 'a path the ebuild fperms escalates by name alone',
      reasons(blockers(%w[opt/app/chrome-sandbox])),
      [['opt/app/chrome-sandbox', 'app-1.ebuild names it']]

check 'a removed file a retained wrapper script runs escalates',
      blockers(%w[opt/app/resources/main.js],
               text_hits: [['opt/app/bin/app', 'exec "$ELECTRON" /opt/app/resources/main.js "$@"']]),
      [['opt/app/resources/main.js', 'opt/app/bin/app names it: exec "$ELECTRON" /opt/app/resources/main.js "$@"']]
check 'a removed Exec= target of a retained desktop entry escalates',
      reasons(blockers(%w[opt/app/start.py],
                       text_hits: [['usr/share/applications/app.desktop', 'Exec=python3 /opt/app/start.py %U']])),
      [['opt/app/start.py', 'usr/share/applications/app.desktop names it']]
check 'a removed Icon= target of a retained desktop entry escalates',
      reasons(blockers(%w[usr/share/pixmaps/app.png],
                       text_hits: [['usr/share/applications/app.desktop', 'Icon=app']])),
      [['usr/share/pixmaps/app.png', 'usr/share/applications/app.desktop names it']]
check 'an icon with a longer name than Icon= does not match it',
      blockers(%w[usr/share/pixmaps/app-old.png], text_hits: [['usr/share/applications/app.desktop', 'Icon=app']]),
      []
check 'unread text files escalate everything',
      reasons(blockers(%w[opt/app/changelog.md], text_complete: false)),
      [['(all)', "the new tree's text files were not all read (one reaches #{AD::TEXT_FILE_CAP} bytes " \
                 "or all exceed #{AD::TEXT_TOTAL_CAP})"]]

# --- the build decides what is left ---------------------------------------------------------
verdict = ->(**kw) { BT.payload_verdict(install: true, version_ok: false, gui_launched: false, gui_failures: [], **kw) }
check 'a version match accepts', verdict.call(version_ok: true), nil
check 'a 15s GUI launch accepts', verdict.call(gui_launched: true), nil
check 'no version match and no GUI launch escalates', verdict.call,
      'smoke inconclusive: no version output matched and no GUI launch ran 15s'
check 'a GUI launch that lost a library escalates despite a version match',
      verdict.call(version_ok: true, gui_failures: [['/usr/bin/app', 'app MISSING A LIBRARY at runtime (libEGL.so)']]),
      'GUI launch probe failed: app MISSING A LIBRARY at runtime (libEGL.so)'
check 'no install escalates', verdict.call(install: false, version_ok: true), 'not installed (--install)'

class SettleProbe < BT
  def initialize(ctx, version_ok:, gui_launched: false)
    super(ctx)
    @smoke_result = [version_ok, gui_launched]
  end

  private

  def install_and_smoke = (@version_ok, @gui_launched = @smoke_result)
end

ev = Autobump::Evidence.new('payload-removals')
settle = lambda do |removed, **smoke|
  c = Autobump::Context.new(payload: true, install: true, evidence: ev, payload_pending: removed)
  SettleProbe.new(c, **smoke).run
  [c.accept_payload, c.accepted_diffs]
rescue Autobump::Escalate => e
  e.message
end
check 'a smoke-tested install accepts the removals for a draft PR',
      settle.call(kiro, version_ok: true),
      [true, ['payload removed paths accepted: opt/app/libEGL.so, opt/app/libGLESv2.so, opt/app/changelog.md']]
many = (1..12).map { |i| "opt/app/doc/note#{i}.md" }
check 'the accepted list names the first ten and counts the rest',
      settle.call(many, version_ok: false, gui_launched: true)[1],
      ["payload removed paths accepted: #{many.first(10).join(', ')} (+2 more)"]
check 'an inconclusive smoke escalates the removals',
      settle.call(kiro, version_ok: false),
      'payload layout changed (3 removed path(s) named nowhere, but smoke inconclusive: ' \
      'no version output matched and no GUI launch ran 15s)'

# smoke_version itself: a version line from a command that failed did not run the app
class VersionProbe < BT
  private

  def install_and_smoke = smoke_version
  def owned_files(_pkg) = ['/usr/bin/app']
end

smoke = lambda do |out, code|
  c = Autobump::Context.new(payload: true, install: true, evidence: ev, payload_pending: kiro, newver: '2.0')
  c.define_singleton_method(:sh) { |*_a, **_kw| [out, code.zero?, code] }
  quiet = $stdout
  $stdout = File.open(File::NULL, 'w')
  begin
    VersionProbe.new(c).run
    c.accept_payload
  ensure
    $stdout = quiet
  end
rescue Autobump::Escalate => e
  e.message[/smoke inconclusive/]
end
check 'a version printed with exit 0 accepts the removals', smoke.call("app 2.0\n", 0), true
check 'a version printed by a failing command does not accept the removals',
      smoke.call("app 2.0: fatal: template.dat missing\n", 1), 'smoke inconclusive'

# --- ArtifactDiff against real trees ----------------------------------------------------------
class TreeProbe < AD
  def initialize(ctx, trees)
    super(ctx)
    @trees = trees
  end

  private

  def payload? = true

  def tree_of(eb, out)
    wd = @trees.fetch(eb)
    system('bash', '-c', 'find "$1" -type f -printf "%P\n" | sort > "$2"', 'bash', wd, out)
    wd
  end
end

Dir.mktmpdir('payload-removals-') do |tmp|
  bin = File.join(tmp, 'bin')
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, 'scanelf'), <<~SH)
    #!/bin/sh
    # stands in for pax-utils: the app binary NEEDs only libffmpeg and libc
    for last; do :; done
    echo "$last/opt/app/app;libffmpeg.so,libc.so.6"
  SH
  FileUtils.chmod(0o755, File.join(bin, 'scanelf'))
  ENV['PATH'] = "#{bin}:#{ENV.fetch('PATH')}"

  build = lambda do |name, files, exec: []|
    root = File.join(tmp, name)
    files.each do |f, body|
      FileUtils.mkdir_p(File.dirname(File.join(root, f)))
      File.write(File.join(root, f), body)
      FileUtils.chmod(exec.include?(f) ? 0o755 : 0o644, File.join(root, f))
    end
    root
  end
  common = { 'opt/app/app' => "\x7fELF", 'opt/app/resources.pak' => '', 'opt/app/icudtl.dat' => '',
             'usr/share/applications/app.desktop' => "[Desktop Entry]\nExec=/opt/app/app %U\nIcon=app\n" }
  run = lambda do |tag, old_extra, new_extra = {}, install: true, ebuild: EBUILD, files_dir: {}, unreadable: nil|
    pkgdir = build.call("#{tag}-pkg", { 'app-2.ebuild' => ebuild }.merge(files_dir))
    old = build.call("#{tag}-old", common.merge(old_extra), exec: %w[opt/app/app opt/app/libEGL.so opt/app/helper])
    new = build.call("#{tag}-new", common.merge(new_extra), exec: %w[opt/app/app opt/app/bin/app])
    FileUtils.chmod(0o000, File.join(new, unreadable)) if unreadable
    cfg = Struct.new(:sudo).new('')
    c = Autobump::Context.new(cfg: cfg, pn: 'app', pkgdir: pkgdir, old_pv: '1', newver: '2', install: install,
                              old_ebuild: File.join(pkgdir, 'app-1.ebuild'), new_ebuild: File.join(pkgdir, 'app-2.ebuild'),
                              evidence: Autobump::Evidence.new('payload-removals'))
    out = $stdout
    $stdout = File.open(File::NULL, 'w')
    begin
      TreeProbe.new(c, 'app-1.ebuild' => old, 'app-2.ebuild' => new).run
      c.payload_pending
    rescue Autobump::Escalate => e
      e.message
    ensure
      $stdout = out
    end
  end

  check 'tree: kiro-style removals wait for the build',
        run.call('kiro', { 'opt/app/libEGL.so' => '', 'opt/app/changelog.md' => "# 1.0\n" }),
        %w[opt/app/changelog.md opt/app/libEGL.so]
  check 'tree: without --install they escalate',
        run.call('noinst', { 'opt/app/changelog.md' => '' }, install: false),
        'payload layout changed ((all): only an install and smoke test can clear them, and this run does not build (--install))'
  check 'tree: a removed executable escalates',
        run.call('exec', { 'opt/app/helper' => "#!/bin/sh\n" }),
        'payload layout changed (opt/app/helper: executable in the old tree)'
  check 'tree: a file a retained wrapper execs escalates',
        run.call('wrap', { 'opt/app/main.js' => '' }, { 'opt/app/bin/app' => "#!/bin/sh\nexec /opt/app/app /opt/app/main.js\n" }),
        'payload layout changed (opt/app/main.js: opt/app/bin/app names it: exec /opt/app/app /opt/app/main.js)'
  check 'tree: a retained config naming the file escalates',
        run.call('json', { 'opt/app/vk_swiftshader_icd.json' => '{}', 'opt/app/libvk_swiftshader.so' => '' },
                 { 'opt/app/vk_swiftshader_icd.json' => '{"library_path": "./libvk_swiftshader.so"}' }),
        'payload layout changed (opt/app/libvk_swiftshader.so: opt/app/vk_swiftshader_icd.json names it: ' \
        '{"library_path": "./libvk_swiftshader.so"})'
  check 'tree: an icon a retained desktop entry names escalates',
        run.call('icon', { 'usr/share/pixmaps/app.png' => '' }),
        'payload layout changed (usr/share/pixmaps/app.png: usr/share/applications/app.desktop names it: Icon=app)'
  check 'tree: a file files/ names escalates',
        run.call('files', { 'opt/app/changelog.md' => '' }, files_dir: { 'files/app-docs.patch' => "+see changelog.md\n" }),
        'payload layout changed (opt/app/changelog.md: files/app-docs.patch names it: +see changelog.md)'
  big = "{\"pad\": \"#{'x' * (300 * 1024)}\"}"
  check 'tree: a retained config at or over the per-file cap escalates',
        run.call('bigjson', { 'opt/app/changelog.md' => '' }, { 'opt/app/config.json' => big }),
        "payload layout changed ((all): the new tree's text files were not all read " \
        "(one reaches #{AD::TEXT_FILE_CAP} bytes or all exceed #{AD::TEXT_TOTAL_CAP}))"
  check 'tree: an executable over the per-file cap is a binary and is skipped',
        run.call('bigbin', { 'opt/app/changelog.md' => '' }, { 'opt/app/app' => "\x7fELF#{'x' * (300 * 1024)}" }),
        %w[opt/app/changelog.md]
  check 'tree: a retained desktop entry with a `:` in its name still names its icon',
        run.call('colon', { 'usr/share/pixmaps/other.png' => '' },
                 { 'usr/share/applications/foo:bar.desktop' => "[Desktop Entry]\nIcon=other\n" }),
        'payload layout changed (usr/share/pixmaps/other.png: usr/share/applications/foo:bar.desktop names it: Icon=other)'

  # a grep that takes its sh wrapper down with a signal makes xargs exit 125, not 124
  killer = File.join(tmp, 'killer')
  FileUtils.mkdir_p(killer)
  File.write(File.join(killer, 'grep'), "#!/bin/sh\nkill -TERM $PPID\n")
  FileUtils.chmod(0o755, File.join(killer, 'grep'))
  path = ENV.fetch('PATH')
  ENV['PATH'] = "#{killer}:#{path}"
  killed = begin
    run.call('killed', { 'opt/app/changelog.md' => '' }).to_s[/\A[^:]+:[^:]+/]
  ensure
    ENV['PATH'] = path
  end
  check 'tree: a grep killed by a signal fails the read and escalates', killed,
        "payload layout changed ((all): the new tree's text files could not be read"

  # root reads a mode-000 file anyway, so only an unprivileged run can make grep fail
  unless Process.uid.zero?
    check 'tree: a text file grep cannot read escalates',
          run.call('unread', { 'opt/app/changelog.md' => '' }, { 'opt/app/app.json' => '{}' }, unreadable: 'opt/app/app.json').to_s[/\A[^:]+:[^:]+/],
          "payload layout changed ((all): the new tree's text files could not be read"
  end
end

puts '----'
if $fail.zero?
  puts 'payload_removals: all passed'
else
  puts "payload_removals: #{$fail} failed"
  exit 1
end
