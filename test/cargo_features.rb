#!/usr/bin/env ruby
# frozen_string_literal: true
# Test ArtifactDiff#source_surface on Cargo features: an added or removed feature counts only
# when the ebuild names it. cc-switch-cli 5.11.1 (cli, test-hooks) and gitoxide 0.60.0 escalated
# on features neither ebuild selects. `default`, every feature under --all-features, and every
# other surface line still count.
# Hermetic -- no portage. Run: ruby test/cargo_features.rb
require 'stringio'
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

Evidence = Struct.new(:dir) do
  def path(name) = File.join(dir, name)
end
Ctx = Struct.new(:evidence, :new_ebuild, :accept_surface, :cfg)

def work(root, name, files)
  src = File.join(root, name, 'pkg-1.0')
  FileUtils.mkdir_p(src)
  files.each { |f, body| File.write(File.join(src, f), body) }
  File.join(root, name)
end

def toml(*features) = "[package]\nname = \"pkg\"\n\n[features]\n#{features.map { |f| "#{f} = []\n" }.join}"

# [escalated?, surface-ignored.txt or nil]
def surface(old_files, new_files, ebuild)
  Dir.mktmpdir do |root|
    ev = File.join(root, 'ev')
    FileUtils.mkdir_p(ev)
    eb = File.join(root, 'pkg-1.1.ebuild')
    File.write(eb, ebuild)
    c = Ctx.new(Evidence.new(ev), eb, false, Struct.new(:sudo).new(''))
    out = $stdout
    $stdout = StringIO.new
    escalated = begin
      Autobump::ArtifactDiff.new(c).send(:source_surface, work(root, 'old', old_files), work(root, 'new', new_files))
      false
    rescue Autobump::Escalate
      true
    ensure
      $stdout = out
    end
    ign = File.join(ev, 'surface-ignored.txt')
    [escalated, File.exist?(ign) ? File.read(ign) : nil]
  end
end

PLAIN = <<~'EB'
  EAPI=8
  inherit cargo
  MY_PN="${PN/-cli/}"
  HOMEPAGE="https://github.com/SaladDay/cc-switch-cli"
  IUSE="test"
  src_prepare() {
  	default
  }
EB

check 'unreferenced features added (cc-switch-cli 5.11.1)',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('cli', 'test-hooks') }, PLAIN),
      [false, "+cargo-feature:cli\n+cargo-feature:test-hooks\n"]
check 'unreferenced feature removed',
      surface({ 'Cargo.toml' => toml('vendored') }, { 'Cargo.toml' => toml }, PLAIN),
      [false, "-cargo-feature:vendored\n"]

FEATURES = PLAIN + <<~'EB'
  src_configure() {
  	cargo_src_configure --features vendored
  }
EB
check 'removed feature passed with --features escalates',
      surface({ 'Cargo.toml' => toml('vendored') }, { 'Cargo.toml' => toml }, FEATURES).first, true

MYFEATURES = PLAIN + <<~'EB'
  IUSE+=" gui"
  src_configure() {
  	local myfeatures=(
  		$(usev gui)
  	)
  	cargo_src_configure
  }
EB
check 'added feature named by IUSE and myfeatures escalates',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('gui') }, MYFEATURES).first, true

check '`gui` is not named by `guide`',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('gui') }, "#{PLAIN}DOCS=( guide.md )\n"),
      [false, "+cargo-feature:gui\n"]
check '`cli` is not named by `client`',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('cli') }, "#{PLAIN}# talks to the client\n"),
      [false, "+cargo-feature:cli\n"]
check '`cli` as a whole word escalates',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('cli') }, "#{PLAIN}IUSE+=\" cli\"\n").first, true

check 'added `default` escalates even when only the phase helper names it',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('cli', 'default') }, PLAIN),
      [true, "+cargo-feature:cli\n"]
check 'added `default` escalates in an ebuild that never names it',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('default') }, "EAPI=8\ninherit cargo\n"),
      [true, nil]
check 'removed `default` escalates',
      surface({ 'Cargo.toml' => toml('default') }, { 'Cargo.toml' => toml }, PLAIN), [true, nil]
check 'unnamed feature under --all-features escalates',
      surface({ 'Cargo.toml' => toml }, { 'Cargo.toml' => toml('extra') },
              "#{PLAIN}src_configure() { cargo_src_configure --all-features; }\n"),
      [true, nil]

check 'non-Cargo surface line escalates beside an ignored feature',
      surface({ 'CMakeLists.txt' => "option(WITH_A \"a\" ON)\n", 'Cargo.toml' => toml },
              { 'CMakeLists.txt' => "option(WITH_A \"a\" ON)\nfind_package(Qt6)\n", 'Cargo.toml' => toml('extra') },
              PLAIN),
      [true, "+cargo-feature:extra\n"]
check 'removed meson option escalates',
      surface({ 'meson_options.txt' => "option('gtk', type: 'boolean')\n" }, { 'meson_options.txt' => '' }, PLAIN),
      [true, nil]

exit($fail.zero? ? 0 : 1)
