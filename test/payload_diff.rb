#!/usr/bin/env ruby
# frozen_string_literal: true
# Test ArtifactDiff.fold_benign: which payload path changes count as benign churn and which
# stay structural (and therefore escalate). The rules are load-bearing in both directions --
# folding too little escalates every bump of a package with bundled artifacts, folding too
# much hides a genuinely removed path -- so pin both.
# Hermetic -- no portage, no git, no filesystem. Run: ruby test/payload_diff.rb
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

F = Autobump::ArtifactDiff.method(:fold_benign)

# --- rule 1: package-version rename ----------------------------------------------------
rm, ad, ch = F.call(%w[opt/foo/foo-1.2.3.so], %w[opt/foo/foo-1.2.4.so], '1.2.3', '1.2.4')
check 'pkg-version rename folds', [rm, ad], [[], []]
# rule 1 drops its pairs before the counter runs, so they are not in churned. Pre-existing
# behaviour, pinned here so the extraction cannot silently change the reported count.
check 'pkg-version rename not counted as churn', ch, 0

# --- rule 2: bundler content-hash rename -----------------------------------------------
rm, ad, = F.call(%w[app/assets/main-a1b2c3d4.js], %w[app/assets/main-e5f6a7b8.js], '1', '2')
check 'asset hash rename folds', [rm, ad], [[], []]
# Outside the old asset dirs, a different basename does not make an exact hash pair.
rm, = F.call(%w[bin/main-a1b2c3d4.bin], %w[bin/other-e5f6a7b8.bin], '1', '2')
check 'unpaired hash stays structural', rm, %w[bin/main-a1b2c3d4.bin]

# Pairing is by directory and basename with only the content hash blanked, not by a
# directory-name allowlist.
ion_dist_removed = %w[
  usr/lib/claude-desktop/resources/ion-dist/_frame-rt/_runtime/kernel.C5XtPPRo.js
  usr/lib/claude-desktop/resources/ion-dist/_frame-rt/_runtime/manifest.064207474966cc9d.json
]
ion_dist_added = %w[
  usr/lib/claude-desktop/resources/ion-dist/_frame-rt/_runtime/kernel.N7qLm2Vx.js
  usr/lib/claude-desktop/resources/ion-dist/_frame-rt/_runtime/manifest.b8d9e0f1a2c3d4e5.json
]
rm, ad, ch = F.call(ion_dist_removed, ion_dist_added, '1', '2')
check 'ion-dist hash rehashes fold', [rm, ad], [[], []]
check 'ion-dist hash rehashes count as churn', ch, 4

# A numeric chunk is not a content hash under rule (2), so its replacement remains visible.
stage_removed = %w[
  opt/SiYuan/resources/stage/build/app/base.5a741c39f95f77975aff.css
  opt/SiYuan/resources/stage/build/mobile/main.128082a998f508728f76.js
  opt/SiYuan/resources/stage/build/export/805.js
]
stage_added = %w[
  opt/SiYuan/resources/stage/build/app/base.f1e2d3c4b5a697887766.css
  opt/SiYuan/resources/stage/build/mobile/main.fedcba98765432100123.js
  opt/SiYuan/resources/stage/build/export/806.js
]
rm, ad, ch = F.call(stage_removed, stage_added, '1', '2')
check 'stage build rehashes and the renumbered chunk all fold', [rm, ad], [[], []]
check 'stage build churn counts every folded path', ch, 6

rm, ad, = F.call(
  %w[usr/lib/claude-desktop/resources/ion-dist/_frame-rt/_runtime/kernel.C5XtPPRo.js],
  [], '1', '2'
)
check 'unpaired content-hash removal stays structural', [rm, ad],
      [%w[usr/lib/claude-desktop/resources/ion-dist/_frame-rt/_runtime/kernel.C5XtPPRo.js], []]

rm, ad, = F.call(
  %w[app/build/main.a1b2c3d4.js app/build/main.e5f6a7b8.js],
  %w[app/build/main.01234567.js], '1', '2'
)
check 'ambiguous hash pairing keeps removals structural', [rm, ad],
      [%w[app/build/main.a1b2c3d4.js app/build/main.e5f6a7b8.js], []]

rm, ad, = F.call(%w[package/prebuilds/linux-x64/copilot-runtime-bin], [], '1', '2')
check 'upstream copilot runtime removal stays structural', [rm, ad],
      [%w[package/prebuilds/linux-x64/copilot-runtime-bin], []]

# A lowercase word is a name, not a hash: a renamed .desktop must stay visible.
rm, ad, = F.call(%w[usr/share/applications/org.example.desktop],
                 %w[usr/share/applications/org.example2.desktop], '1', '2')
check 'renamed desktop file stays structural', rm, %w[usr/share/applications/org.example.desktop]

rm, ad, = F.call(%w[AppDir/share/dns/root.hints], [], '1', '2')
check 'root hints removal stays structural', [rm, ad], [%w[AppDir/share/dns/root.hints], []]

# --- rule 3: independent version stream (the jetbrains-toolbox case) -------------------
# 26 jars moved 0.8.6635 -> 0.8.6806 while the package went 3.6.2.85969 -> 3.6.3.86383.
old_jars = %w[agent-client app-logger app-network app-os app-ssh].map { |n| "bin/lib/#{n}-0.8.6635.jar" }
new_jars = %w[agent-client app-logger app-network app-os app-ssh].map { |n| "bin/lib/#{n}-0.8.6806.jar" }
rm, ad, ch = F.call(old_jars, new_jars, '3.6.2.85969', '3.6.3.86383')
check 'independent version stream folds', [rm, ad], [[], []]
check 'independent stream counted as churn', ch, 10
# a genuinely new component alongside the renames stays visible as an addition
rm, ad, = F.call(old_jars, new_jars + %w[bin/lib/agent-handshake-0.8.6806.jar],
                 '3.6.2.85969', '3.6.3.86383')
check 'new component still reported', [rm, ad], [[], %w[bin/lib/agent-handshake-0.8.6806.jar]]

# --- rule 3 must NOT over-fold ---------------------------------------------------------
# a real removal with no counterpart stays structural
rm, = F.call(%w[bin/lib/dropped-0.8.6635.jar], [], '1', '2')
check 'unpaired removal stays structural', rm, %w[bin/lib/dropped-0.8.6635.jar]
# same basename, different directory: a moved file is a structural change, not a rename
rm, ad, = F.call(%w[bin/lib/x-1.0.0.jar], %w[share/lib/x-1.0.1.jar], '1', '2')
check 'cross-directory move stays structural', [rm, ad], [%w[bin/lib/x-1.0.0.jar], %w[share/lib/x-1.0.1.jar]]
# a renamed directory: every file under it changes dirname, so none of it folds
rm, ad, = F.call(%w[lib/python3.12/os.py lib/python3.12/re.py],
                 %w[lib/python3.13/os.py lib/python3.13/re.py], '1', '2')
check 'renamed directory stays structural', [rm.size, ad.size], [2, 2]
# ambiguous pairing: two removals normalise to one key, so neither folds
rm, ad, = F.call(%w[bin/lib/x-1.0.0.jar bin/lib/x-2.0.0.jar], %w[bin/lib/x-3.0.0.jar], '1', '2')
check 'ambiguous 2:1 pairing does not fold', [rm.size, ad.size], [2, 1]
# a bare integer is not a version run: an icon size drop must still be reported
rm, ad, = F.call(%w[share/icons/16x16/foo.png], [], '1', '2')
check 'dropped icon size stays structural', [rm, ad], [%w[share/icons/16x16/foo.png], []]
# renaming to a different name in the same dir is not a version rename
rm, ad, = F.call(%w[bin/lib/alpha-1.0.0.jar], %w[bin/lib/beta-1.0.1.jar], '1', '2')
check 'different basename stays structural', [rm, ad], [%w[bin/lib/alpha-1.0.0.jar], %w[bin/lib/beta-1.0.1.jar]]

# --- no-change and empty input ---------------------------------------------------------
check 'empty diff -> empty', F.call([], [], '1', '2'), [[], [], 0]


# --- rule 4: renumbered bundler chunk ----------------------------------------------------
# webpack renumbers chunks every build: cursor moved dist/657.js to dist/61.js, siyuan
# stage/build/export/805.js to 806.js.
rm, ad, ch = F.call(%w[usr/share/cursor/resources/app/extensions/cursor-agent-host/dist/657.js],
                    %w[usr/share/cursor/resources/app/extensions/cursor-agent-host/dist/61.js], '1', '2')
check 'renumbered chunk folds', [rm, ad], [[], []]
check 'renumbered chunk counts as churn', ch, 2

# a rebuilt bundle renames its whole directory at once, so the two sides do not pair
rm, ad, ch = F.call(%w[opt/app/dist/111.js opt/app/dist/154.js opt/app/dist/154.js.LICENSE.txt],
                    %w[opt/app/dist/1053.js opt/app/dist/1178.js opt/app/dist/1198.js
                       opt/app/dist/276.js.LICENSE.txt opt/app/dist/2142.js.map], '1', '2')
check 'a renumbered chunk set folds whatever the counts', [rm, ad], [[], []]
check 'the whole set counts as churn', ch, 8

rm, = F.call(%w[opt/app/dist/111.js opt/app/dist/154.js], %w[opt/app/other/1053.js], '1', '2')
check 'a dist that emptied out stays structural', rm, %w[opt/app/dist/111.js opt/app/dist/154.js]

rm, = F.call(%w[opt/app/dist/111.js opt/app/dist/154.js opt/app/dist/165.js], %w[opt/app/dist/1053.js], '1', '2')
check 'a dist that came back smaller stays structural', rm,
      %w[opt/app/dist/111.js opt/app/dist/154.js opt/app/dist/165.js]

# the sourcemap and licence of a hash-renamed asset are the same churn as the asset
rm, ad, ch = F.call(%w[opt/app/assets/index-A1b2C3d.js opt/app/assets/index-A1b2C3d.js.map],
                    %w[opt/app/assets/index-Z9y8X7w.js opt/app/assets/index-Z9y8X7w.js.map], '1', '2')
check 'a hash rename folds with its companions', [rm, ad], [[], []]
check 'the companions count as churn', ch, 4

rm, = F.call(%w[usr/share/icons/hicolor/16x16/apps/icon16.png],
             %w[usr/share/icons/hicolor/32x32/apps/icon32.png], '1', '2')
check 'a dropped icon size is not a chunk renumber', rm,
      %w[usr/share/icons/hicolor/16x16/apps/icon16.png]

rm, = F.call(%w[opt/app/dist/657.js], %w[opt/app/other/61.js], '1', '2')
check 'chunk renumber across directories stays structural', rm, %w[opt/app/dist/657.js]

rm, = F.call(%w[opt/app/dist/657.bin], %w[opt/app/dist/61.bin], '1', '2')
check 'a numeric basename with another extension stays structural', rm, %w[opt/app/dist/657.bin]

rm, ad, = F.call([], %w[opt/app/dist/1053.js], '1', '2')
check 'a chunk that is only added is not a rebuild', [rm, ad], [[], %w[opt/app/dist/1053.js]]

# an ebuild that spells its version differently in the payload: ungoogled-chromium-bin builds
# MY_PV="${PV/_p/-}" and unpacks into a directory named after it
rm, ad, = F.call(%w[ungoogled-chromium-1.2.3-1-x86_64_linux/chrome
                    ungoogled-chromium-1.2.3-1-x86_64_linux/locales/en-US.pak],
                 %w[ungoogled-chromium-1.2.4-1-x86_64_linux/chrome
                    ungoogled-chromium-1.2.4-1-x86_64_linux/locales/en-US.pak],
                 '1.2.3_p1', '1.2.4_p1')
check 'a MY_PV directory rename folds', [rm, ad], [[], []]

check 'the forms a version can take in a path',
      Autobump::ArtifactDiff.version_forms('152.0.7977.64_p1'),
      %w[152.0.7977.64_p1 152.0.7977.64-1 152.0.7977.64]
check 'a version with no suffix has one form',
      Autobump::ArtifactDiff.version_forms('1.2.3'), %w[1.2.3]
check 'a bare number is not used as a substitution key',
      Autobump::ArtifactDiff.version_forms('2'), %w[2]
# with a suffixed single-digit version, a bare core would substitute all over the path
rm, = F.call(%w[usr/share/icons/icon2.png], %w[usr/share/icons/icon3.png], '2_p1', '3_p1')
check 'a dropped icon is not a version rename', rm, %w[usr/share/icons/icon2.png]

# a vite bundle keeps a stable id in front of the build hash: only the last token rehashes
rm, ad, = F.call(%w[app/assets/chunk-2GRJ4B5K-Dtk3djQK.js app/assets/chunk-2Q5K7J3B-COdn04Wu.js],
                 %w[app/assets/chunk-2GRJ4B5K-DrXvAXa3.js app/assets/chunk-2Q5K7J3B-BkL9zzQp.js],
                 '1', '2')
check 'a rehash behind a stable id folds', [rm, ad], [[], []]

# ...and two different ids do not pair by name; only the directory count clears them
rm, = F.call(%w[app/assets/chunk-2GRJ4B5K-Dtk3djQK.js app/assets/chunk-7QQQQQQQ-Bz6qKO3a.js],
             %w[app/assets/chunk-9ZZZZZZZ-DrXvAXa3.js], '1', '2')
check 'different stable ids do not pair by name', rm.size, 2

# a deployment fingerprint rehashes in front of the chunk id
digest_a = '3' + 'a' * 47
digest_b = '4' + 'b' * 47
rm, ad, = F.call(["app/dist/#{digest_a}-CVu4teRk.js"], ["app/dist/#{digest_b}-CVu4teRk.js"], '1', '2')
check 'a fingerprint rehash folds', [rm, ad], [[], []]

# a chunk id that changed with the content: no name can pair it, so the directory's own count
# is the check - claude-desktop swaps two of its assets for two under different ids
rm, ad, = F.call(["app/dist/#{digest_a}-CVu4teRk.js"], ["app/dist/#{digest_b}-DifferentX.js"], '1', '2')
check 'a chunk swapped for one under another id folds', [rm, ad], [[], []]

digest_c = '5' + 'c' * 47
rm, = F.call(["app/dist/#{digest_a}-CVu4teRk.js", "app/dist/#{digest_c}-Cn24xRWk.js"],
             ["app/dist/#{digest_b}-DifferentX.js"], '1', '2')
check 'a directory that came back smaller still escalates', rm.size, 2

# kiro rehashes a chunk under an upper-case hash, which reads as a name to the pairing rules
kiro = 'kiro/dist/assets/gitGraphDiagram-DS77QQ5N-'
rm, ad, = F.call(["#{kiro}Bz6qKO3a.js"], ["#{kiro}BIS-CJUO.js"], '1.0.436', '1.0.437')
check 'an upper-case rehash folds on the directory count', [rm, ad], [[], []]

rm, = F.call(%w[app/dist/runtime-modules.js], %w[app/dist/runtime-services.js], '1', '2')
check 'a word is not a hash, so a renamed script stays structural', rm, %w[app/dist/runtime-modules.js]

rm, = F.call(["app/lib/libfoo-Bz6qKO3a.so"], ["app/lib/libbar-CVu4teRk.so"], '1', '2')
check 'a library is not a chunk', rm, ["app/lib/libfoo-Bz6qKO3a.so"]

# a bundle output directory: every name is a content hash, so a rebuild churns an arbitrary
# subset - claude-desktop's ion-dist/assets/v1 holds 2760 of them and drops 16 whose ids moved
bundle = 'app/ion-dist/assets/v1'
survivors = (1..40).map { |i| "#{bundle}/#{format('%048x', i)}-Chunk#{i}Aa.js" }
rm = %W[#{bundle}/c09ddf347-mnuumf4t.js #{bundle}/shared-5--MfpzEVV.js]
ad = %W[#{bundle}/d41d8cd98-QQzzWWpp.js #{bundle}/shared-9--BbCcDdE.js]
left_rm, left_ad, = F.call(rm, ad, '1', '2', new_tree: survivors + ad)
check 'a rebuilt bundle directory folds the ids that moved', [left_rm, left_ad], [[], []]

collapsed = survivors.first(9)
gone = survivors.last(31)
left_rm, = F.call(gone, [], '1', '2', new_tree: collapsed)
check 'a bundle directory that lost more than it kept still escalates', left_rm.size, 31

extra = "#{bundle}/#{'e' * 48}-NewChunkA.js"
left_rm, = F.call(rm + ["#{bundle}/index.html"], ad + [extra], '1', '2',
                  new_tree: survivors + ad + [extra])
check 'a named file dropped from a bundle directory is still a removal',
      left_rm, ["#{bundle}/index.html"]

tiny = %w[app/blobs/beta-Zz98Yy76.bin app/blobs/keep-Mm44Nn55.bin]
left_rm, = F.call(%w[app/blobs/alpha-Ab12Cd34.bin], %w[app/blobs/beta-Zz98Yy76.bin], '1', '2',
                  new_tree: tiny)
check 'two hash-named files do not make a directory a bundle',
      left_rm, %w[app/blobs/alpha-Ab12Cd34.bin]

# cursor's cursor-agent-host/dist repartitions: 135 numbered chunks come back as 116
dist = 'app/extensions/cursor-agent-host/dist'
kept = (1000..1115).map { |i| "#{dist}/#{i}.js" }
dropped = (2000..2025).map { |i| "#{dist}/#{i}.js" }
fresh = (3000..3006).map { |i| "#{dist}/#{i}.js" }
left_rm, left_ad, = F.call(dropped, fresh, '3.19.12', '3.19.13', new_tree: kept + fresh)
check 'a repartitioned chunk directory folds even though it came back smaller',
      [left_rm, left_ad], [[], []]

# rebased-bin carries the package version in the top directory and its own build number in the
# file, so neither number matches on its own
left_rm, left_ad, = F.call(%w[rebased-bin-1.1.14/lib/build-marker-IC-262.9437.SNAPSHOT],
                           %w[rebased-bin-1.1.15/lib/build-marker-IC-262.10315.SNAPSHOT],
                           '1.1.14', '1.1.15')
check 'a versioned directory does not hide an independently-versioned file',
      [left_rm, left_ad], [[], []]

left_rm, = F.call(%w[rebased-bin-1.1.14/lib/build-marker-IC-262.9437.SNAPSHOT],
                  %w[rebased-bin-1.1.15/lib/other-marker-IC-262.10315.SNAPSHOT], '1.1.14', '1.1.15')
check 'a file that changed name across that directory is still a removal', left_rm.size, 1

named = (1..40).map { |i| "app/images/icon-#{i}.png" }
left_rm, = F.call(%w[app/images/clawd-magnifier.gif], %w[app/images/clawd-lens.gif], '1', '2',
                  new_tree: named + %w[app/images/clawd-lens.gif])
check 'an ordinary directory is not a bundle', left_rm, %w[app/images/clawd-magnifier.gif]

puts '----'
if $fail.zero?
  puts 'payload_diff: all passed'
else
  puts "payload_diff: #{$fail} failed"
  exit 1
end
