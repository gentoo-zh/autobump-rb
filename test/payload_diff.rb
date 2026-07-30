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
# outside an asset dir the same shape is NOT hash churn; it still has to pair some other way
rm, = F.call(%w[bin/main-a1b2c3d4.bin], %w[bin/other-e5f6a7b8.bin], '1', '2')
check 'hash rule needs an asset dir', rm, %w[bin/main-a1b2c3d4.bin]

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

puts '----'
if $fail.zero?
  puts 'payload_diff: all passed'
else
  puts "payload_diff: #{$fail} failed"
  exit 1
end
