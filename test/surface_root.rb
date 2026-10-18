#!/usr/bin/env ruby
# frozen_string_literal: true
# Test ArtifactDiff::SURFACE_SH: the surface is read from S, not from whichever WORKDIR
# directory find lists first. cc-switch unpacks cargo_home and dist beside its source, and
# an old surface read from cargo_home came back empty, so every feature looked added.
# Hermetic -- no portage. Run: ruby test/surface_root.rb
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

def surface(build, env)
  out = File.join(build, 'surface.txt')
  system({ 'SUDO' => '' }, 'bash', '-c', Autobump::ArtifactDiff::SURFACE_SH, 'bash',
         File.join(build, 'work'), out, env)
  File.read(out)
end

Dir.mktmpdir do |build|
  work = File.join(build, 'work')
  # enough vendor directories that the first one listed is almost never the source
  30.times do |i|
    crate = File.join(work, "vendor#{i}", 'crate')
    FileUtils.mkdir_p(crate)
    File.write(File.join(crate, 'Cargo.toml'), "[features]\nvendored = []\n")
  end
  src = File.join(work, 'pkg-1.0', 'src-tauri')
  FileUtils.mkdir_p(src)
  File.write(File.join(src, 'Cargo.toml'), "[package]\nname = \"pkg\"\n\n[features]\ndefault = []\ntest-hooks = []\n")
  FileUtils.mkdir_p(File.join(build, 'temp'))
  env = File.join(build, 'temp', 'environment')
  File.write(env, "declare -x PV=\"1.0\"\ndeclare -x S=\"#{work}/pkg-1.0\"\n")

  check 'surface read from S', surface(build, env), "cargo-feature:default\ncargo-feature:test-hooks\n"
  File.write(env, "declare -- S=\"#{work}/pkg-1.0\"\n")
  check 'S declared without export', surface(build, env), "cargo-feature:default\ncargo-feature:test-hooks\n"
  File.write(env, "declare -x S=\"#{work}/missing\"\n")
  check 'missing S falls back to a WORKDIR directory', surface(build, env).empty?, false
  check 'no environment falls back to a WORKDIR directory', surface(build, File.join(build, 'none')).empty?, false
end

exit($fail.zero? ? 0 : 1)
