#!/usr/bin/env ruby
# frozen_string_literal: true
# Test which structural payload removals wait for the build and which still escalate. Last
# month sixteen "payload layout changed" escalations were pure renames (kiro, openchamber,
# claude-desktop, cursor ...); the rules below let those through only when nothing can still
# need the removed file, and every class of real break a reviewer listed stays escalated.
# Hermetic: the trees are temp directories, scanelf is a stub on PATH, nothing is emerged.
# Run: ruby test/payload_removals.rb
require 'fileutils'
require 'open3'
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
# --- upstream text that names another file with the same ending ----------------------------
# A removal is named by an upstream line only where the name starts and, when a directory is
# written in front of it, that directory is the removed file's own.
start = 'app-1.0/lib/start.py'
{
  'the same directory behind a variable' => 'CLASS_PATH="$CLASS_PATH:$IDE_HOME/lib/start.py"',
  'a bare name' => 'exec python3 start.py "$@"',
  'a name at the start of the line' => 'start.py --help',
  './' => 'exec python3 ./start.py',
  '../' => 'exec python3 ../start.py',
  'a variable directory' => 'exec python3 $LIB/start.py',
  'a braced variable directory' => 'exec python3 ${LIB}/start.py',
  'a quoted variable directory' => 'exec python3 "$LIB"/start.py',
  'a `:` in front' => 'PYTHONSTARTUP=lib:start.py',
  'a longer name after it' => 'exec python3 /opt/app/lib/start.pyc'
}.each do |what, line|
  check "an upstream line naming the removed file with #{what} escalates",
        reasons(blockers([start], text_hits: [['app-1.1/bin/app.sh', line]])),
        [[start, 'app-1.1/bin/app.sh names it']]
end
check 'an upstream line naming the removed file under a renumbered directory escalates',
      reasons(blockers(%w[app-1.0/start.py], text_hits: [['app-1.1/bin/app.sh', 'exec /opt/app-1.1/start.py']])),
      [['app-1.0/start.py', 'app-1.1/bin/app.sh names it']]
check 'a removed file at the top of the tree is named under any directory',
      reasons(blockers(%w[start.py], text_hits: [['bin/app.sh', 'exec /opt/app/start.py']])),
      [['start.py', 'bin/app.sh names it']]
{
  'a longer dotted name' => 'exec python3 $IDE_HOME/lib/jackson.start.py',
  'a longer hyphenated name' => 'exec python3 $IDE_HOME/lib/my-start.py',
  'a longer underscored name' => 'exec python3 $IDE_HOME/lib/my_start.py',
  'a longer word' => 'exec python3 $IDE_HOME/lib/restart.py',
  'another directory' => 'exec python3 $IDE_HOME/plugins/lib/modules/start.py'
}.each do |what, line|
  check "an upstream line naming #{what} does not name the removed file",
        blockers([start], text_hits: [['app-1.1/bin/app.sh', line]]), []
end
check 'the ebuild still names the removed file inside a longer name',
      reasons(blockers([start], refs: { 'app-1.ebuild' => "\tfperms +x /opt/app/lib/jackson.start.py\n" })),
      [[start, 'app-1.ebuild names it']]
check 'a files/ wrapper still names the removed file under another directory',
      reasons(blockers([start], refs: { 'app-1.ebuild' => EBUILD, 'files/app.sh' => "exec /opt/other/start.py\n" })),
      [[start, 'files/app.sh names it']]

# Two escalations from the overlay as they were posted: every removal with the reason it was
# blocked. Both bumps merged as pure renames.
FIXTURES = File.join(__dir__, 'payload_removals')
posted = lambda do |name|
  File.readlines(File.join(FIXTURES, "#{name}.blocked.tsv"), chomp: true).map { |l| l.split("\t", 2) }
end
hits_of = ->(rows) { rows.filter_map { |_p, why| why.match(/\A(\S+) names it: (.*)\z/)&.captures } }
ebuild_of = ->(name) { { "#{name}.ebuild" => File.read(File.join(FIXTURES, "#{name}.ebuild")) } }

# pi-coding-agent-bin 1.5.0 (issue 16060): upstream dropped the sandbox example, and the new
# examples/tsconfig.json names a dev-tree ../../../packages/chord/src/index.ts. The bare
# package.json in pi/package.json's own build script is still a hit, so this bump escalates.
pi = posted.call('pi-coding-agent-bin-1.5.0')
pi_removed = %w[.gitignore index.ts package-lock.json package.json].map { |f| "pi/examples/extensions/sandbox/#{f}" }
check 'pi: a src/index.ts of another package does not name the removed example index.ts',
      reasons(blockers(pi_removed, refs: ebuild_of.call('pi-coding-agent-bin-1.5.0'), text_hits: hits_of.call(pi),
                                   new_tree: %w[pi/pi pi/package.json pi/examples/tsconfig.json])),
      [['pi/examples/extensions/sandbox/package.json', 'pi/package.json names it']]

# rebased-bin 1.1.24 (issue 16362): lib/annotations.jar became
# lib/intellij.libraries.jackson.annotations.jar, and other jars moved under plugins/*/lib/modules/
rebased = posted.call('rebased-bin-1.1.24')
named, native = rebased.partition { |_p, why| why.include?(' names it: ') }
rebased_tree = %w[rebased-bin-1.1.24/bin/rebased.sh rebased-bin-1.1.24/product-info.json]
check 'rebased: no removed jar is named by a longer jar name or by its new plugins/ location',
      blockers(named.map(&:first), refs: ebuild_of.call('rebased-bin-1.1.24'), text_hits: hits_of.call(rebased),
                                   new_tree: rebased_tree), []
check 'rebased: the removed native libraries still escalate',
      blockers(native.map(&:first), refs: ebuild_of.call('rebased-bin-1.1.24'), text_hits: hits_of.call(rebased),
                                    new_tree: rebased_tree), native
check 'rebased: the fixture still holds every jar the old matcher blocked', [named.size, native.size], [47, 4]

check 'unread text files escalate everything',
      reasons(blockers(%w[opt/app/changelog.md], text_complete: false)),
      [['(all)', "the new tree's text files were not all read (they exceed #{AD::TEXT_TOTAL_CAP} bytes in all)"]]

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
# [accepted, differences that draft the PR, informational notes]; added is ArtifactDiff's raw
# tree-added.txt, nil when it left none
settle = lambda do |removed, added: [], **smoke|
  if added
    ev.write('tree-added.txt', added.map { |a| "#{a}\n" }.join)
  else
    FileUtils.rm_f(ev.path('tree-added.txt'))
  end
  c = Autobump::Context.new(payload: true, install: true, evidence: ev, payload_pending: removed)
  SettleProbe.new(c, **smoke).run
  [c.accept_payload, c.accepted_diffs, c.info_notes]
rescue Autobump::Escalate => e
  e.message
end
check 'a smoke-tested install accepts the removals for a draft PR',
      settle.call(kiro, version_ok: true),
      [true, ['payload removed paths accepted: opt/app/libEGL.so, opt/app/libGLESv2.so, opt/app/changelog.md'], nil]
many = (1..12).map { |i| "opt/app/doc/note#{i}.md" }
check 'the accepted list names the first ten and counts the rest',
      settle.call(many, version_ok: false, gui_launched: true)[1],
      ["payload removed paths accepted: #{many.first(10).join(', ')} (+2 more)"]
check 'an inconclusive smoke escalates the removals',
      settle.call(kiro, version_ok: false),
      'payload layout changed (3 removed path(s) named nowhere, but smoke inconclusive: ' \
      'no version output matched and no GUI launch ran 15s)'

# Only data the smoke test vouches for leaves the PR ready; the line stays in the body as a note.
# The removals of the last two weeks' payload drafts (overlay PRs), as settle_payload_removals got them:
claude = %w[Tray-Win32-Dark.ico Tray-Win32.ico TrayIconTemplate.png TrayIconTemplate@2x.png TrayIconTemplate@3x.png]
         .map { |f| "usr/lib/claude-desktop/resources/#{f}" }
check 'claude-desktop 16147: tray icons only are a note, not a draft',
      settle.call(claude, version_ok: false, gui_launched: true),
      [true, nil, ["payload removed paths accepted (data files only): #{claude.join(', ')}"]]
check 'chatgpt-desktop 15887: one example html is a note',
      settle.call(%w[usr/lib/chatgpt/resources/plugins/openai-bundled/plugins/visualize/skills/visualize/examples/calendar.html],
                  version_ok: true)[1], nil
check 'reasonix-bin 16371: one font is a note',
      settle.call(%w[frontend-next/dist/fonts/studio-mono-400.ttf], version_ok: true)[1], nil
cache = 'opt/T3 Code (Beta)/resources/server-compile-cache'
# the first ten as the PR listed them; it named five more without their hashes
t3 = %w[02278096 167ab736 17599c36 17d5677f 198f1d6c 1bec94f7 28b4e94e 517a9bb3 59b4686e 7b12861e
        8a0b3c4d 9e8f7a6b a1b2c3d4 c0ffee00 d00dfeed].map { |h| "#{cache}/#{h}" }
check 't3code-bin 16620: a rebuilt compile cache is a note',
      settle.call(t3, added: ["#{cache}/3f9a01bc", "#{cache}/77aa21de"], version_ok: true)[1], nil
check 'the same cache with nothing added in its place drafts',
      settle.call(t3, added: ["opt/T3 Code (Beta)/resources/other/3f9a01bc"], version_ok: true)[2], nil
check 'and so does one with no tree-added.txt to read', settle.call(t3, added: nil, version_ok: true)[2], nil
check 'a hex-named file outside a cache directory drafts even when replaced',
      Autobump::BuildTest.data_only_removals?(['usr/bin/deadbeef12'], ['usr/bin/cafebabe34']), false
siyuan = %w[opt/SiYuan/locales/pt-PT.pak opt/SiYuan/resources/stage/build/app/602.04bc8988a95e6a337cd5.js
            opt/SiYuan/resources/stage/build/app/base.2a97d70b345d5431d8ce.css
            opt/SiYuan/resources/stage/loading-pure.svg opt/SiYuan/resources/stage/loading.svg]
check 'siyuan-bin 16468: a removed script chunk among data still drafts',
      settle.call(siyuan, version_ok: true),
      [true, ["payload removed paths accepted: #{siyuan.join(', ')}"], nil]
check 'jetbrains-toolbox 15946: a removed jar still drafts',
      settle.call(%w[jetbrains-toolbox/bin/lib/app-os-win.jar], version_ok: true)[1],
      ['payload removed paths accepted: jetbrains-toolbox/bin/lib/app-os-win.jar']

data = ->(removed, added = []) { BT.data_only_removals?(removed, added) }
%w[js mjs cjs jar py so node wasm sh ts dat bin].each do |ext|
  check "a removed .#{ext} is not data", data.call(["opt/app/resources/a.#{ext}", 'opt/app/resources/b.png']), false
end
check 'an extensionless file that is no hash is not data', data.call(%w[opt/app/helper]), false
check 'a hex name replaced in another directory is not data',
      data.call(%w[opt/app/cache/0123abcd], %w[opt/app/other/89efcdab]), false
check 'a hex name is not its own replacement', data.call(%w[opt/app/cache/0123abcd], %w[opt/app/cache/0123abcd]), false
check 'twenty data files are a note', data.call((1..20).map { |i| "opt/app/icons/#{i}.png" }), true
check 'twenty-one are not', data.call((1..21).map { |i| "opt/app/icons/#{i}.png" }), false
check 'nothing removed is no data-only removal', data.call([]), false
check 'locale json is data', data.call(%w[opt/app/locales/pt-PT.json usr/lib/claude-desktop/resources/de-DE.json]), true
check 'package.json is not', data.call(%w[opt/app/locales/package.json]), false
check 'json an app may load code by is not',
      [data.call(%w[opt/app/resources/app/product.json]), data.call(%w[opt/app/config.json])], [false, false]
check 'upper-case extensions count', data.call(%w[opt/app/Logo.PNG]), true

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
  # siyuan ships a 7 MB one-line mermaid icons.json and locale JSON over the per-file cap
  big = "{\"pad\": \"#{'x' * (300 * 1024)}\"}"
  check 'tree: a retained config over the per-file cap is read, and naming nothing it lets the build decide',
        run.call('bigjson', { 'opt/app/changelog.md' => '' }, { 'opt/app/config.json' => big }),
        %w[opt/app/changelog.md]
  check 'tree: a retained config over the per-file cap naming the file escalates with the name alone',
        run.call('bigname', { 'opt/app/chunk.1a2b.js' => '' }, { 'opt/app/config.json' => big.sub('pad', 'chunk.1a2b.js') }),
        'payload layout changed (opt/app/chunk.1a2b.js: opt/app/config.json names it: chunk.1a2b.js)'
  check 'tree: a removed executable beside a config over the per-file cap escalates',
        run.call('bigexec', { 'opt/app/helper' => "#!/bin/sh\n" }, { 'opt/app/config.json' => big }),
        'payload layout changed (opt/app/helper: executable in the old tree)'
  check 'tree: an executable over the per-file cap is a binary and is skipped',
        run.call('bigbin', { 'opt/app/changelog.md' => '' }, { 'opt/app/app' => "\x7fELF#{'x' * (300 * 1024)}" }),
        %w[opt/app/changelog.md]
  check 'tree: a retained desktop entry with a `:` in its name still names its icon',
        run.call('colon', { 'usr/share/pixmaps/other.png' => '' },
                 { 'usr/share/applications/foo:bar.desktop' => "[Desktop Entry]\nIcon=other\n" }),
        'payload layout changed (usr/share/pixmaps/other.png: usr/share/applications/foo:bar.desktop names it: Icon=other)'

  # the total cap still bounds the read, over-cap configs included
  total = build.call('total', { 'a.json' => big, 'b.json' => big })
  pats = File.join(tmp, 'total-patterns.txt')
  File.write(pats, "chunk.1a2b.js\n")
  _out, err, = Open3.capture3({ 'SUDO' => '' }, 'bash', '-c', AD::TEXT_HITS_SH, 'bash', total, pats,
                              AD::TEXT_FILE_CAP.to_s, (big.bytesize + 1).to_s)
  check 'tree: configs over the total cap are reported TRUNCATED', err, "TRUNCATED\n"

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
