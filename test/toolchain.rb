#!/usr/bin/env ruby
# frozen_string_literal: true
# Test the Go/Rust toolchain floor stage: what it reads from go.mod and Cargo.toml, which
# ebuild lines it raises, and when it escalates instead. Hermetic: the source tree, the
# ::gentoo eclasses and portageq are stubbed. Run: ruby test/toolchain.rb
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

T = Autobump::Toolchain

GO_MODULE_ECLASS = <<~'SH'
  if [[ ! ${GO_OPTIONAL} ]]; then
  	BDEPEND=">=dev-lang/go-1.24.11:="
  fi
SH

RUST_ECLASS = <<~'SH'
  declare -a -g -r _RUST_SLOTS_ORDERED=(
  	"1.99.0"
  	"1.91.0"
  	"1.90.0"
  )
SH

BEST = { 'dev-lang/go' => '1.27.2', 'dev-lang/rust' => '1.98.1', 'dev-lang/rust-bin' => '1.99.0' }.freeze

class MemoryEvidence
  attr_reader :files

  def initialize = (@files = {})
  def write(name, content) = (@files[name] = content)
  def path(name) = "/evidence/#{name}"
  def dir = '/evidence'
end

Ctx = Struct.new(:payload, :new_ebuild, :evidence, :bundles, :accepted_diffs, keyword_init: true)

# The new source tree is a hash of paths under /w; S is /w/src.
class StubToolchain < Autobump::Toolchain
  attr_reader :reads

  def initialize(ctx, tree, unpacked: true)
    super(ctx)
    @tree = tree
    @unpacked = unpacked
    @reads = []
  end

  private

  def new_workdir = @unpacked ? '/w' : nil
  def cargo_members(root) = @tree.keys.select { |k| k.start_with?("#{root}/") && k.end_with?('/Cargo.toml') && !k.include?('/vendor/') }
  def source_dir(_work) = '/w/src'
  def read(path) = (@reads << path; @tree[path])
  def gentoo_eclass(name) = { 'go-module' => GO_MODULE_ECLASS, 'rust' => RUST_ECLASS }[name]
  def best_visible(atom) = BEST[atom]
end

# [ebuild text after the stage, accepted differences, escalation message or nil, stub]
def run_stage(ebuild, tree = nil, payload: false, bundles: nil, unpacked: true, **files)
  tree ||= files # a hash written without braces arrives as keywords
  Dir.mktmpdir('autobump-toolchain-test-') do |dir|
    path = File.join(dir, 'pkg-2.0.ebuild')
    File.write(path, ebuild)
    ctx = Ctx.new(payload: payload, new_ebuild: path, evidence: MemoryEvidence.new, bundles: bundles)
    stage = StubToolchain.new(ctx, tree, unpacked: unpacked)
    escalation = begin
      stage.run
      nil
    rescue Autobump::Escalate => e
      e.message
    end
    [File.read(path), ctx.accepted_diffs, escalation, stage]
  end
end

def go_ebuild(dep) = "EAPI=8\ninherit go-module\n\nBDEPEND=\"#{dep}\"\n"

# --- go ----------------------------------------------------------------------------------
# net-proxy/queqiao: the manual bump that this stage replaces changed 1.25.13 to 1.26.9
text, notes, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'),
                              '/w/src/go.mod' => "module example.com/q\n\ngo 1.26.9\n")
check 'go: a higher go.mod floor raises the explicit atom', text, go_ebuild('>=dev-lang/go-1.26.9')
check 'go: the raise is recorded as an accepted difference', notes,
      ['go floor raised: 1.25.13 -> 1.26.9 (go.mod: go 1.26.9)']
check 'go: a raise does not escalate', esc, nil

text, notes, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'), '/w/src/go.mod' => "go 1.25.13\n")
check 'go: an equal floor leaves the ebuild alone', [text, notes, esc], [go_ebuild('>=dev-lang/go-1.25.13'), nil, nil]
text, notes, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'), '/w/src/go.mod' => "go 1.24\n")
check 'go: a lower floor is never lowered', [text, notes, esc], [go_ebuild('>=dev-lang/go-1.25.13'), nil, nil]
text, notes, esc, = run_stage(go_ebuild('>=dev-lang/go-1.26'), '/w/src/go.mod' => "go 1.26.0\n")
check 'go: 1.26 and 1.26.0 are the same floor', [text, notes, esc], [go_ebuild('>=dev-lang/go-1.26'), nil, nil]

text, _, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'),
                          '/w/src/go.mod' => "go 1.25.0\n\ntoolchain go1.27.1\n")
check 'go: the toolchain line is no floor', [text, esc], [go_ebuild('>=dev-lang/go-1.25.13'), nil]

text, _, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13:=[foo(+)] app-arch/unzip'),
                          '/w/src/go.mod' => "go 1.26.9\n")
check 'go: slot and USE dependencies on the atom are kept',
      [text, esc], [go_ebuild('>=dev-lang/go-1.26.9:=[foo(+)] app-arch/unzip'), nil]

text, notes, esc, = run_stage(go_ebuild('dev-lang/go-bootstrap'), '/w/src/go.mod' => "go 1.25.0\n")
check 'go: dev-lang/go-bootstrap is not a dev-lang/go atom', notes.to_a.first&.include?('no >=dev-lang/go atom'), true
check 'go: the note leaves the ebuild alone', [text, esc], [go_ebuild('dev-lang/go-bootstrap'), nil]

text, notes, esc, = run_stage("EAPI=8\ninherit go-module\n", '/w/src/go.mod' => "go 1.26.0\n")
check 'go: no atom and a floor above the eclass notes instead of escalating', esc, nil
check 'go: the note asks for the atom and quotes go.mod and the eclass floor', notes,
      ['go.mod requires go 1.26.0 (go 1.26.0), above the go-module.eclass floor 1.24.11, and the ebuild ' \
       'has no >=dev-lang/go atom; add >=dev-lang/go-1.26.0:= to BDEPEND']
check 'go: no atom is added', text, "EAPI=8\ninherit go-module\n"
_, _, esc, = run_stage("EAPI=8\ninherit go-module\n", '/w/src/go.mod' => "go 1.28.0\n")
check 'go: no atom and a floor above the best dev-lang/go still escalates', esc&.include?('(1.27.2)'), true
_, notes, esc, = run_stage("EAPI=8\ninherit go-module\n", '/w/src/go.mod' => "go 1.24.0\n")
check 'go: no atom and a floor under the eclass passes', [notes, esc], [nil, nil]

text, _, esc, = run_stage(go_ebuild('>=dev-lang/go-1.26.9'), '/w/src/go.mod' => "go 1.28.0\n")
check 'go: a floor above the best dev-lang/go escalates', esc&.include?('best dev-lang/go in ::gentoo (1.27.2)'), true
check 'go: an unbuildable floor is not written', text, go_ebuild('>=dev-lang/go-1.26.9')
_, _, esc, = run_stage(go_ebuild('>=dev-lang/go-1.26.9'), '/w/src/go.mod' => "go 1.28rc1\n")
check 'go: a release candidate compares as _rc', esc&.include?('needs Go 1.28.0_rc1'), true

_, _, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'), { '/w/go.mod' => "go 1.26.9\n" })
check 'go: go.mod above S is the module S builds', esc, nil
check 'go: go.mod is read from S upwards', run_stage(go_ebuild('>=dev-lang/go-1.25.13'),
                                                     { '/w/go.mod' => "go 1.26.9\n" })[0],
      go_ebuild('>=dev-lang/go-1.26.9')

two = "EAPI=8\ninherit go-module\nBDEPEND=\">=dev-lang/go-1.25.13\"\nfoo? ( >=dev-lang/go-1.25.0 )\n"
text, _, esc, = run_stage(two, '/w/src/go.mod' => "go 1.26.9\n")
check 'go: two >= atoms escalate rather than guess', [text, esc&.include?('not one >=dev-lang/go atom')], [two, true]

text, notes, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'), { '/w/src/go.mod' => "go 1.26.9\n" },
                              bundles: Object.new)
check 'go: a regenerated vendor bundle notes instead of rewriting',
      [text, esc, notes.to_a.first&.include?('vendor bundle')], [go_ebuild('>=dev-lang/go-1.25.13'), nil, true]
_, _, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'), { '/w/src/go.mod' => "go 1.28.0\n" },
                       bundles: Object.new)
check 'go: a regenerated vendor bundle above the best dev-lang/go escalates', esc&.include?('(1.27.2)'), true

commented = "EAPI=8\ninherit go-module\n# BDEPEND=\">=dev-lang/go-1.30.0\"\nBDEPEND=\">=dev-lang/go-1.25.13\"\n"
text, = run_stage(commented, '/w/src/go.mod' => "go 1.26.9\n")
check 'go: a commented atom is neither a floor nor rewritten', text, commented.sub('1.25.13', '1.26.9')

# fix 1: an atom other than a lower bound escalates only when it rules the new floor out
upper = go_ebuild('>=dev-lang/go-1.25.13 <dev-lang/go-1.27')
text, notes, esc, = run_stage(upper, '/w/src/go.mod' => "go 1.25.0\n")
check 'go: an upper bound with an unchanged go.mod passes', [text, notes, esc], [upper, nil, nil]
_, _, esc, = run_stage(upper, '/w/src/go.mod' => "go 1.27.0\n")
check 'go: an upper bound the new floor reaches escalates', esc&.include?('rules out'), true
blocker = go_ebuild('>=dev-lang/go-1.25.13 !<dev-lang/go-1.20')
text, = run_stage(blocker, '/w/src/go.mod' => "go 1.26.9\n")
check 'go: a blocker is neither a floor nor a conflict', text, blocker.sub('1.25.13', '1.26.9')
glob = "EAPI=8\nBDEPEND=\"=dev-lang/go-1.22*\"\n"
_, notes, esc, = run_stage(glob, '/w/src/go.mod' => "go 1.22.5\n")
check 'go: =dev-lang/go-1.22* accepts go 1.22.5', [notes, esc], [nil, nil]
_, _, esc, = run_stage(glob, '/w/src/go.mod' => "go 1.23.0\n")
check 'go: =dev-lang/go-1.22* rules out go 1.23.0', esc&.include?('rules out'), true

# fix 5: a trailing comment holds no atom
trailing = go_ebuild('>=dev-lang/go-1.25.13') + "# was >=dev-lang/go-1.20.0\nIUSE=\"\" # >=dev-lang/go-1.21.0\n"
text, _, esc, = run_stage(trailing, '/w/src/go.mod' => "go 1.26.9\n")
check 'go: an atom in a trailing comment is neither counted nor rewritten',
      [text, esc], [trailing.sub('1.25.13', '1.26.9'), nil]

# fix 6: a revision on the atom
text, = run_stage(go_ebuild('>=dev-lang/go-1.25.13-r1:='), '/w/src/go.mod' => "go 1.26.9\n")
check 'go: an atom with -rN is read and raised', text, go_ebuild('>=dev-lang/go-1.26.9:=')
_, notes, = run_stage(go_ebuild('>=dev-lang/go-1.26.9-r1'), '/w/src/go.mod' => "go 1.26.9\n")
check 'go: an atom with -rN at the go.mod floor stays', notes, nil

# fix 7: the eclass floor holds beside a lower explicit atom
text, notes, = run_stage(go_ebuild('>=dev-lang/go-1.22.0'), '/w/src/go.mod' => "go 1.24.0\n")
check 'go: an explicit atom under the eclass floor is not raised when the eclass covers go.mod',
      [text, notes], [go_ebuild('>=dev-lang/go-1.22.0'), nil]

# no new tree: neither a silent pass nor a defer, a note for the draft
text, notes, esc, = run_stage(go_ebuild('>=dev-lang/go-1.25.13'), { '/w/src/go.mod' => "go 1.26.9\n" },
                              unpacked: false)
check 'an unpackable new tree leaves a note and the ebuild alone', [text, notes, esc],
      [go_ebuild('>=dev-lang/go-1.25.13'), ['toolchain floor not checked: the new source could not be unpacked here'], nil]

# --- rust --------------------------------------------------------------------------------
def rust_ebuild(min) = "EAPI=8\n\n#{min}\ninherit cargo\n"

text, notes, esc, = run_stage(rust_ebuild('RUST_MIN_VER="1.85.0"'),
                              '/w/src/Cargo.toml' => "[package]\nname = \"x\"\nrust-version = \"1.88\"\n")
check 'rust: a higher rust-version raises RUST_MIN_VER', [text, esc], [rust_ebuild('RUST_MIN_VER="1.88.0"'), nil]
check 'rust: the raise is recorded as an accepted difference', notes,
      ['rust floor raised: RUST_MIN_VER 1.85.0 -> 1.88.0 (Cargo.toml: rust-version = "1.88")']

text, notes, = run_stage(rust_ebuild('RUST_MIN_VER="1.88.0"'),
                         '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.88\"\n")
check 'rust: an equal floor leaves the ebuild alone', [text, notes], [rust_ebuild('RUST_MIN_VER="1.88.0"'), nil]
text, = run_stage(rust_ebuild('RUST_MIN_VER="1.92.0"'), '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.80\"\n")
check 'rust: a lower floor is never lowered', text, rust_ebuild('RUST_MIN_VER="1.92.0"')

ws = { '/w/src/Cargo.toml' => "[package]\nname = \"x\"\nrust-version.workspace = true\n",
       '/w/Cargo.toml' => "[workspace]\nmembers = [\"src\"]\n\n[workspace.package]\nrust-version = \"1.91.0\"\n" }
text, = run_stage(rust_ebuild('RUST_MIN_VER="1.85.0"'), ws)
check 'rust: [workspace.package] rust-version is read from the workspace root', text,
      rust_ebuild('RUST_MIN_VER="1.91.0"')

text, notes, esc, = run_stage(rust_ebuild(''), '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.92\"\n")
check 'rust: no RUST_MIN_VER and a floor above the eclass default notes instead of escalating', esc, nil
check 'rust: the note asks for RUST_MIN_VER and quotes Cargo.toml', notes,
      ['Cargo.toml requires rust 1.92.0 (rust-version = "1.92"), above rust.eclass\'s oldest slot 1.90.0, ' \
       'and the ebuild sets no RUST_MIN_VER; add RUST_MIN_VER="1.92.0"']
check 'rust: no RUST_MIN_VER is added', text, rust_ebuild('')
_, notes, esc, = run_stage(rust_ebuild(''), '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.85\"\n")
check 'rust: no RUST_MIN_VER and a floor under the eclass default passes', [notes, esc], [nil, nil]
_, _, esc, = run_stage(rust_ebuild(''), '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.100\"\n")
check 'rust: no RUST_MIN_VER and a floor above the best rust still escalates', esc&.include?('(1.99.0)'), true
text, notes, esc, = run_stage(rust_ebuild('RUST_MIN_VER="1.85.0"'),
                              { '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.88\"\n" }, bundles: Object.new)
check 'rust: a regenerated vendor bundle notes instead of rewriting',
      [text, esc, notes.to_a.first&.include?('vendor bundle')], [rust_ebuild('RUST_MIN_VER="1.85.0"'), nil, true]

text, _, esc, = run_stage(rust_ebuild('RUST_MIN_VER="1.85.0"'),
                          '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.100\"\n")
check 'rust: a floor above the best rust or rust-bin escalates', esc&.include?('(1.99.0)'), true
check 'rust: an unbuildable floor is not written', text, rust_ebuild('RUST_MIN_VER="1.85.0"')

maxed = "EAPI=8\nRUST_MAX_VER=\"1.90.0\"\nRUST_MIN_VER=\"1.85.0\"\ninherit cargo\n"
text, _, esc, = run_stage(maxed, '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.91\"\n")
check 'rust: RUST_MAX_VER below the new floor escalates and stays', [text, esc&.include?('RUST_MAX_VER=1.90.0')],
      [maxed, true]

text, = run_stage(rust_ebuild('RUST_MIN_VER="1.85.0"'),
                  '/w/src/Cargo.toml' => "[package]\nname = \"x\"\n\n[dependencies.y]\nrust-version = \"1.95\"\n")
check 'rust: rust-version outside [package] is no floor', text, rust_ebuild('RUST_MIN_VER="1.85.0"')

# fix 2: every RUST_MIN_VER assignment counts
cond = "EAPI=8\nRUST_MIN_VER=\"1.88.0\"\nif [[ ${PV} == 9999 ]]; then\n\tRUST_MIN_VER=\"1.85.0\"\nfi\ninherit cargo\n"
text, _, esc, = run_stage(cond, '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.88\"\n")
check 'rust: a lower conditional RUST_MIN_VER escalates and stays', [text, esc&.include?('unindented literal')],
      [cond, true]
indented = "EAPI=8\n  RUST_MIN_VER=\"1.85.0\"\ninherit cargo\n"
text, _, esc, = run_stage(indented, '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.88\"\n")
check 'rust: an indented RUST_MIN_VER is not rewritten', [text, esc&.include?('unindented literal')], [indented, true]
_, notes, esc, = run_stage(cond, '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.80\"\n")
check 'rust: two RUST_MIN_VER both above rust-version pass', [notes, esc], [nil, nil]
commented_min = rust_ebuild("RUST_MIN_VER=\"1.85.0\" # RUST_MIN_VER=\"1.70.0\"")
text, = run_stage(commented_min, '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.88\"\n")
check 'rust: RUST_MIN_VER in a trailing comment is no second assignment', text,
      commented_min.sub('="1.85.0"', '="1.88.0"')

inline = "EAPI=8\nRUST_MIN_VER=\"1.88.0\"\n[[ ${PV} == 9999 ]] && RUST_MIN_VER=\"1.85.0\"\ninherit cargo\n"
text, _, esc, = run_stage(inline, '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.88\"\n")
check 'rust: an assignment after && counts', [text, esc&.include?('unindented literal')], [inline, true]

# fix 3: a virtual workspace whose members state rust-version
virt = { '/w/src/Cargo.toml' => "[workspace]\nmembers = [\"a\", \"b\"]\n",
         '/w/src/a/Cargo.toml' => "[package]\nname = \"a\"\nrust-version = \"1.86\"\n",
         '/w/src/b/Cargo.toml' => "[package]\nname = \"b\"\nrust-version = \"1.89\"\n",
         '/w/src/vendor/z/Cargo.toml' => "[package]\nrust-version = \"1.98\"\n" }
text, notes, esc, = run_stage(rust_ebuild('RUST_MIN_VER="1.85.0"'), virt)
check 'rust: a member above RUST_MIN_VER leaves a note, not an edit', [text, esc], [rust_ebuild('RUST_MIN_VER="1.85.0"'), nil]
check 'rust: the note names the highest member, vendored crates left out', notes,
      ['workspace member b/Cargo.toml requires rust 1.89.0 (rust-version = "1.89"), above RUST_MIN_VER=1.85.0; ' \
       "the package's own rust-version could not be read, so check which member the ebuild builds"]
_, notes, = run_stage(rust_ebuild('RUST_MIN_VER="1.90.0"'), virt)
check 'rust: members under RUST_MIN_VER pass', notes, nil
_, notes, = run_stage(rust_ebuild(''), { '/w/src/a/Cargo.toml' => "[package]\nrust-version = \"1.92\"\n" })
check 'rust: no Cargo.toml in S still reads the members', notes.to_a.first&.include?("oldest slot 1.90.0"), true

# fix 8: an array of tables ends [package]
check 'toml: [[bin]] ends the [package] section',
      T.toml_value("[package]\nname = \"x\"\n[[bin]]\nrust-version = \"1.99\"\n", 'package', 'rust-version'), nil

# --- both, and what is skipped -----------------------------------------------------------
both = "EAPI=8\nRUST_MIN_VER=\"1.85.0\"\ninherit cargo go-module\nBDEPEND=\">=dev-lang/go-1.25.13\"\n"
text, notes, = run_stage(both, '/w/src/go.mod' => "go 1.26.9\n",
                               '/w/src/Cargo.toml' => "[package]\nrust-version = \"1.88\"\n")
check 'both floors are raised in one pass', text, both.sub('1.25.13', '1.26.9').sub('1.85.0', '1.88.0')
check 'both raises are recorded', notes&.size, 2

text, notes, esc, stage = run_stage(go_ebuild('>=dev-lang/go-1.25.13'),
                                    { '/w/src/go.mod' => "go 1.26.9\n" }, payload: true)
check 'payload: a prebuilt package is skipped', [text, notes, esc], [go_ebuild('>=dev-lang/go-1.25.13'), nil, nil]
check 'payload: nothing is read from the tree', stage.reads, []

plain = "EAPI=8\ninherit cmake\n"
_, _, _, stage = run_stage(plain, '/w/src/go.mod' => "go 1.30.0\n")
check 'neither Go nor Rust: nothing is read', stage.reads, []

# --- pure helpers and wiring -------------------------------------------------------------
check 'pad: two components gain .0', T.pad('1.26'), '1.26.0'
check 'pad: a suffix stays after the padding', T.pad('1.28_rc1'), '1.28.0_rc1'
check 'pad: three components stay', T.pad('1.26.9'), '1.26.9'
check 'eclass floor is read from go-module.eclass', T.eclass_go_floor(GO_MODULE_ECLASS), '1.24.11'
check 'eclass default is the oldest rust slot', T.eclass_rust_default(RUST_ECLASS), '1.90.0'
cli = File.read(File.expand_path('../lib/autobump/cli.rb', __dir__))
check 'cli runs the stage after the artifact diff and before the build test',
      cli.match?(/ArtifactDiff\.new\(ctx\)\.run[^\n]*\n\s*Toolchain\.new\(ctx\)\.run\n\s*BuildTest\.new\(ctx\)\.run/), true

puts '----'
puts "toolchain: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
