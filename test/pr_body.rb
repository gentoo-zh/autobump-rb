#!/usr/bin/env ruby
# frozen_string_literal: true
# Golden test for the PR body (stage 8, PR#pr_body): render across the situations that
# matter and assert the structure. Hermetic -- no network, no gh/git; the maintainer cc
# (which shells out) is stubbed. Complements test/decisions.sh, which only covers the
# classifier. Run: ruby test/pr_body.rb   (also `rake`).
require 'tmpdir'
require_relative '../lib/autobump'

# a render helper + a controllable cc, so the body builds without shelling out
module Autobump
  class PR
    attr_accessor :cc_stub
    def maintainer_ccs = (cc_stub || '')
    def body_for(ctx) = (@c = ctx; pr_body)
  end
end

def render(context, cc: '')
  p = Autobump::PR.allocate
  p.cc_stub = cc
  p.body_for(context)
end

def ctx(ev, **kw) = Autobump::Context.new(evidence: ev, **kw)

def ev_with(pn, files = {})
  e = Autobump::Evidence.new(pn)
  files.each { |name, content| e.write(name, content) }
  e
end

$fail = 0
def check_eq(name, got, want)
  if got == want
    puts "ok   #{name}"
  else
    $fail += 1
    puts "FAIL #{name}\n       got  #{got.inspect}\n       want #{want.inspect}"
  end
end

def check(name, body, must: [], absent: [])
  errs = []
  Array(must).each   { |m| errs << "missing #{m.inspect}"     unless body.include?(m) }
  Array(absent).each { |a| errs << "unexpected #{a.inspect}"  if body.include?(a) }
  errs << 'body contains CJK (must be English-only)' if body =~ /\p{Han}/
  if errs.empty?
    puts "ok   #{name}"
  else
    $fail += 1
    puts "FAIL #{name}"
    errs.each { |e| puts "       #{e}" }
    puts body.gsub(/^/, '       | ')
  end
end

# 0. a rewritten variable: the reviewer gets the source and the old->new token
check 'payload: rewritten variable is shown with its source',
      render(ctx(ev_with('r', 'rewrite.txt' => "variable=MY_COMMIT\nold_value=2ba48ff3\n" \
                                               "new_value=280eca29\nsource_url=https://cursor.com/api/download\n"),
                 pkg: 'app-editors/cursor', old_pvr: '3.18.9', newver: '3.18.25', old_pv: '3.18.9',
                 payload: true, smoke: 'installed')),
      must: ['- rewrote `MY_COMMIT` 2ba48ff3 → 280eca29 from https://cursor.com/api/download']

check 'a bump with no rewrite says nothing about one',
      render(ctx(ev_with('r2'), pkg: 'net-misc/tsshd', old_pvr: '0.1.8', newver: '0.1.9',
                 old_pv: '0.1.8', payload: false, smoke: 'installed')),
      absent: ['rewrote']

# A. source bump, build surface unchanged -> one plain line, no fold
check 'source: no surface change',
      render(ctx(ev_with('a', 'surface-added.txt' => '', 'surface-removed.txt' => ''),
                 pkg: 'net-misc/tsshd', old_pvr: '0.1.8', newver: '0.1.9', old_pv: '0.1.8',
                 payload: false, issue: '11090', smoke: '--version ok: tsshd 0.1.9'), cc: '@vimimg'),
      must: ['**`net-misc/tsshd`** 0.1.8 → 0.1.9', '- [x] emerge build + install',
             '- [x] `pkgcheck scan --commits --net` clean', '- smoke: --version ok: tsshd 0.1.9',
             'diff vs 0.1.8: no build-option surface changes', 'Closes #11090 · cc @vimimg'],
      absent: ['<details>', 'not compared', 'Warning: ']

# B. payload bump with real add + remove -> folded diff, both shown, PATH-SORTED
check 'payload: add+remove folded, path-sorted (rename adjacent)',
      render(ctx(ev_with('b',
                         'tree-removed-real.txt' => "usr/bin/foo-helper\nusr/lib/foo/plugins/old-export.node\n",
                         'tree-added-real.txt'   => "usr/lib/foo/libEGL.so\nusr/lib/foo/plugins/new-export.node\nusr/lib/foo/resources/locales/pt-BR.pak\n"),
                 pkg: 'net-misc/foo-bin', old_pvr: '26.6.0.0', newver: '26.6.1.0', old_pv: '26.6.0.0',
                 payload: true, issue: '10931', smoke: '--version ok: foo 26.6.1.0')),
      must: ['**payload diff vs 26.6.0.0** (+3/-2)', '<details><summary>show</summary>', "```diff",
             '- usr/bin/foo-helper',
             "+ usr/lib/foo/plugins/new-export.node\n- usr/lib/foo/plugins/old-export.node", # sort keeps the rename together
             'Closes #10931']

# C. upstream dropped the old distfile -> cannot compare, warn (no fold)
check 'payload: old distfile gone -> warn',
      render(ctx(ev_with('c'),
                 pkg: 'app-misc/apifox', old_pvr: '2.8.38', newver: '2.8.39', old_pv: '2.8.38',
                 payload: true, old_distfile_missing: true, issue: '11081', smoke: 'installed')),
      must: ['Warning: no old→new diff', 'check the payload before merging'],
      absent: ['<details>']

# D. source build surface changed -> folded diff, both +/- shown
check 'source: surface changed -> folded diff',
      render(ctx(ev_with('d', 'surface-added.txt' => "cmake-WITH_QT6:\nmeson-option:wayland\n",
                              'surface-removed.txt' => "cmake-WITH_QT5:\n"),
                 pkg: 'x11-misc/bar', old_pvr: '2.0', newver: '2.1', old_pv: '2.0',
                 payload: false, smoke: '--version ok: bar 2.1')),
      must: ['**build-option surface diff vs 2.0** (+2/-1)', '<details>',
             '+ cmake-WITH_QT6:', '- cmake-WITH_QT5:']

# E. source surface not comparable (unpack blocked) + multi-arch draft
check 'source: not compared + multiarch',
      render(ctx(ev_with('e'),
                 pkg: 'x/y', old_pvr: '3.0', newver: '3.1', old_pv: '3.0',
                 payload: false, multiarch: true, smoke: 'installed')),
      must: ['build-option surface not compared', 'the emerge build gate vouches'],
      absent: ['<details>', 'Warning: amd64 only']

# F. no issue and no cc -> no trailing meta line at all
check 'no issue / no cc -> no meta line',
      render(ctx(ev_with('f', 'surface-added.txt' => '', 'surface-removed.txt' => ''),
                 pkg: 'a/b', old_pvr: '1', newver: '2', old_pv: '1', payload: false, smoke: 'ok')),
      must: ['no build-option surface changes'],
      absent: ['Closes #', 'cc @']

# G. cap: a very large payload delta is truncated with a "… N more" marker
big = (1..150).map { |i| format('usr/lib/x/file-%03d.dat', i) }.join("\n")
check 'cap: >120 entries truncated',
      render(ctx(ev_with('g', 'tree-added-real.txt' => big + "\n", 'tree-removed-real.txt' => ''),
                 pkg: 'p/q-bin', old_pvr: '1', newver: '2', old_pv: '1', payload: true, smoke: 'ok')),
      must: ['**payload diff vs 1** (+150/-0)', '… 30 more']

# H2. a removal never sorts past the cap: additions are truncated, removals are all shown
many_added = (1..150).map { |i| format('usr/lib/x/added-%03d.dat', i) }.join("\n")
removed_late = "usr/lib/x/zz-removed-1.so\nusr/lib/x/zz-removed-2.so"
check 'cap: every removal survives a wall of additions',
      render(ctx(ev_with('h2', 'tree-added-real.txt' => many_added + "\n",
                               'tree-removed-real.txt' => removed_late + "\n"),
                 pkg: 'p/q-bin', old_pvr: '1', newver: '2', old_pv: '1', payload: true, smoke: 'ok')),
      must: ['- usr/lib/x/zz-removed-1.so', '- usr/lib/x/zz-removed-2.so', '… 32 more additions']

# H. content-hash asset churn only (structural add/remove empty) -> no dump, churn noted, no escalate
check 'payload: asset churn only -> no structural change, churn counted',
      render(ctx(ev_with('h', 'tree-added-real.txt' => '', 'tree-removed-real.txt' => '',
                              'tree-churn-count.txt' => '1000'),
                 pkg: 'app-misc/foo-bin', old_pvr: '1.0', newver: '1.1', old_pv: '1.0',
                 payload: true, smoke: '--version ok: foo 1.1')),
      must: ['no structural payload changes', '1000 bundled assets rebuilt'],
      absent: ['<details>', '.js']

# I. a multi-arch bump is opened as a draft; a single-arch one is not
draft = Autobump::PR.create_args(repo: 'gentoo-zh/overlay', head: 'b', title: 't', body_file: 'f',
                                 multiarch: true)
plain = Autobump::PR.create_args(repo: 'gentoo-zh/overlay', head: 'b', title: 't', body_file: 'f',
                                 multiarch: false)
check_eq 'multi-arch opens a draft', draft.include?('--draft'), true
check_eq 'single-arch does not', plain.include?('--draft'), false

# the open-PR guard: a blip must not cost a bump that is already built, and a refusal must
# say what gh said
stub = File.join(Dir.mktmpdir('autobump-gh-'), 'gh')
File.write(stub, "#!/bin/sh\necho 'gh: HTTP 502 Bad Gateway' >&2\nexit 1\n")
File.chmod(0o755, stub)
path = ENV['PATH']
ENV['PATH'] = "#{File.dirname(stub)}:#{path}"
started = Time.now
open, reason = Autobump::PR.open_pr_for('demo/overlay', 'a-branch')
elapsed = Time.now - started
ENV['PATH'] = path

check_eq 'a failing query answers nothing', open, nil
check_eq 'and carries the reason gh gave', reason, 'gh: HTTP 502 Bad Gateway'
check_eq 'after retrying', elapsed > 3, true

# a push GitHub refuses for the App's permissions is not something a retry fixes
refused = " ! [remote rejected]  b -> b (refusing to allow a GitHub App to create or update " \
          "workflow `.github/workflows/overlay.toml` without `workflows` permission)"
check_eq 'a workflows-permission refusal is recognised', Autobump::PR.workflow_push_refused?(refused), true
check_eq 'an ordinary push failure is not',
         Autobump::PR.workflow_push_refused?('error: failed to push some refs to ...'), false

puts '----'
puts "pr_body: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
