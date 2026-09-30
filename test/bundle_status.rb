#!/usr/bin/env ruby
# frozen_string_literal: true
# What --bundle-status turns a bundle 404 into: which fetch URIs a snapshot covers, the
# classify bypass for them, and the defer / escalate the fetch stage raises.
# Hermetic -- no portage, no network: curl and portageq are stubs. Run: ruby test/bundle_status.rb
require 'fileutils'
require 'json'
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

TestConfig = Struct.new(:op_timeout, :sudo)
MIRRORS = 'https://distfiles.gentoo.org/distfiles https://mirror.example/gentoo'
NOW = Time.utc(2026, 9, 30, 12, 0, 0)
CLOCK = -> { NOW }
PKG = 'dev-util/deepseek-harness'
VER = '0.2.0_rc2'
REPO = 'gentoo-zh-drafts/deepseek-harness'
TAG = '0.2.0-rc.2'
RELEASE = "https://github.com/#{REPO}/releases/download/#{TAG}"
RUN = "https://github.com/#{REPO}/actions/runs/7"

def producer(status: 'completed', conclusion: 'success', minutes_ago: 60, run: RUN)
  { 'workflow' => 'node_modules.yml', 'run_url' => run, 'status' => status, 'conclusion' => conclusion,
    'completed_at' => minutes_ago && (NOW - (minutes_ago * 60)).utc.iso8601 }
end

def bundle(state: 'ready', producers: [producer], repo: REPO, tag: TAG, id: 'node_modules')
  { 'id' => id, 'repo' => repo, 'release_tag' => tag, 'state' => state, 'reason' => 'fixture',
    'producers' => producers, 'release_url' => "https://github.com/#{repo}/releases/tag/#{tag}" }
end

def snapshot(bundles, package: PKG, version: VER)
  { 'schema' => 1, 'controller_run' => 'local', 'observed_at' => NOW.iso8601,
    'targets' => [{ 'package' => package, 'version' => version, 'state' => 'ready', 'bundles' => bundles }] }
end

def status(*bundles, package: PKG, version: VER)
  Autobump::BundleStatus.new(snapshot(bundles, package: package, version: version),
                             package: package, version: version, clock: CLOCK)
end

def with_stubs(dir, curl_code: '404')
  bindir = File.join(dir, 'bin')
  FileUtils.mkdir_p(bindir)
  { 'portageq' => "printf '%s\\n' '#{MIRRORS}'", 'curl' => "printf '%s' '#{curl_code}'" }.each do |name, body|
    File.write(File.join(bindir, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(bindir, name))
  end
  old_path = ENV['PATH']
  stdout = $stdout
  ENV['PATH'] = "#{bindir}:#{old_path}"
  $stdout = StringIO.new
  yield
ensure
  $stdout = stdout
  ENV['PATH'] = old_path
end

Outcome = Struct.new(:error, :reason, :result, :stdout, keyword_init: true)

# Run the fetch stage on a manifest log; the outcome is the raised class, its message, and
# the result.json the stage left in the evidence pack.
def fetch(log, bundles, code: 1)
  Dir.mktmpdir('autobump-bundle-status-') do |pkgdir|
    old = File.join(pkgdir, 'pkg-1.0.ebuild')
    File.write(old, "EAPI=8\n")
    evidence = Autobump::Evidence.new('bundle-status')
    context = Autobump::Context.new(
      cfg: TestConfig.new(30, ''), pkgdir: pkgdir, newver: '1.1', bundles: bundles,
      old_ebuild: old, new_ebuild: File.join(pkgdir, 'pkg-1.1.ebuild'), evidence: evidence
    )
    replies = {
      %w[ebuild pkg-1.0.ebuild fetch] => ['', true, 0],
      %w[ebuild pkg-1.1.ebuild manifest] => [log, false, code]
    }
    context.define_singleton_method(:sh) do |*command, **options|
      replies.fetch(command) { raise "unexpected command: #{command.inspect} #{options.inspect}" }
    end
    out = nil
    error = nil
    with_stubs(pkgdir) do
      Autobump::Distfiles.new(context).run
    rescue Autobump::Abort, Autobump::Escalate => e
      error = e
    ensure
      out = $stdout.string
    end
    result = File.exist?(evidence.path('result.json')) ? JSON.parse(File.read(evidence.path('result.json'))) : nil
    FileUtils.rm_rf(evidence.dir)
    Outcome.new(error: error&.class, reason: error&.message, result: result, stdout: out)
  end
end

def log_404(*uris) = uris.map { |u| ">>> Downloading '#{u}'\nERROR 404: Not Found.\n" }.join
def log_saved(uri) = ">>> Downloading '#{uri}'\n'#{File.basename(uri)}' saved [1024/1024]\n"

# --- loading: every bad snapshot is a hard failure, never a silent run without it
def load_refused(content, package: PKG, version: VER)
  Dir.mktmpdir('autobump-bundle-load-') do |dir|
    path = File.join(dir, 'bundles.json')
    File.write(path, content) if content
    Autobump::BundleStatus.load(path, package: package, version: version, clock: CLOCK)
    nil
  rescue Autobump::Abort => e
    e.message
  end
end

good = JSON.generate(snapshot([bundle]))
check 'a valid snapshot loads', load_refused(good), nil
check 'a missing file is refused', load_refused(nil)&.include?('no such file'), true
check 'unparsable JSON is refused', load_refused('{"schema": 1,')&.include?('not readable JSON'), true
check 'another schema is refused', load_refused(JSON.generate(snapshot([bundle]).merge('schema' => 2)))&.include?('schema 2'), true
check 'no target for the version is refused', load_refused(good, version: '0.2.0')&.include?('no target'), true
check 'no target for the package is refused', load_refused(good, package: 'dev-util/other')&.include?('no target'), true
check 'a target without bundles is refused', load_refused(JSON.generate(snapshot([])))&.include?('lists no bundles'), true
check 'an unknown bundle state is refused', load_refused(JSON.generate(snapshot([bundle(state: 'submitted')])))&.include?('state'), true
bad_time = bundle(producers: [producer.merge('completed_at' => 'yesterday')])
check 'a completed_at that is not ISO 8601 is refused', load_refused(JSON.generate(snapshot([bad_time])))&.include?('ISO 8601'), true
{ 'an empty producer' => {},
  'a producer without a workflow' => producer.merge('workflow' => ''),
  'an unknown producer status' => producer.merge('status' => 'done'),
  'an unknown producer conclusion' => producer.merge('conclusion' => 'ok'),
  'a run_url that is not a string' => producer.merge('run_url' => 7) }.each do |name, p|
  check "#{name} is refused", load_refused(JSON.generate(snapshot([bundle(producers: [p])])))&.include?('producer'), true
end
conclusions = %w[success failure cancelled skipped timed_out neutral action_required stale startup_failure]
check 'every GitHub conclusion loads', conclusions.filter_map { |c|
  load_refused(JSON.generate(snapshot([bundle(producers: [producer(conclusion: c)])])))
}, []

# --- which URIs a bundle covers: host, repo and release tag exactly
s = status(bundle)
check 'a .tar.zst asset of the release is covered', s.covering("#{RELEASE}/deepseek-harness-0.2.0-rc.2-node_modules.tar.zst")&.id, 'node_modules'
check 'the MY_PV-expanded tag, not the Gentoo version, is what matches',
      [s.covering("#{RELEASE}/x.tar.xz").nil?,
       s.covering("https://github.com/#{REPO}/releases/download/#{VER}/x.tar.xz").nil?], [false, true]
check 'another repo on the same host is not covered',
      s.covering("https://github.com/deepseek/harness/releases/download/#{TAG}/harness.tar.gz"), nil
check 'another tag of the same repo is not covered',
      s.covering("https://github.com/#{REPO}/releases/download/0.2.0-rc.1/x.tar.xz"), nil
check 'a tag that only prefixes the release tag is not covered',
      status(bundle(tag: 'v1.0')).covering("https://github.com/#{REPO}/releases/download/v1.0.1/x.tar.xz"), nil
check 'another host with the same path is not covered',
      s.covering("https://mirror.example/#{REPO}/releases/download/#{TAG}/x.tar.xz"), nil
check 'the release page itself is not an asset', s.covering("#{RELEASE}/"), nil

# --- the fetch stage's decision on a covered 404
asset = "#{RELEASE}/deepseek-harness-0.2.0-rc.2-node_modules.tar.zst"

o = fetch(log_404(asset), status(bundle(state: 'pending', producers: [producer(status: 'in_progress', conclusion: nil, minutes_ago: nil)])))
check 'pending bundle defers', [o.error, o.reason], [Autobump::Abort, "bundle pending: #{REPO}@#{TAG} (#{RUN})"]
check 'the defer is marked as a bundle defer', o.result&.values_at('bundle', 'exit'), [true, 2]
check 'the result line reaches stdout', o.stdout.lines.any? { |l| l.start_with?('result: {"bundle":true') }, true

o = fetch(log_404(asset), status(bundle(state: 'unknown', producers: [])))
check 'unknown bundle defers', [o.error, o.reason&.start_with?('bundle pending:')], [Autobump::Abort, true]

o = fetch(log_404(asset), status(bundle(producers: [producer(minutes_ago: 5)])))
check 'producer success under 15 min defers', [o.error, o.reason&.start_with?("bundle pending: #{REPO}@#{TAG} (#{RUN})")],
      [Autobump::Abort, true]

o = fetch(log_404(asset), status(bundle(producers: [producer(minutes_ago: 15)])))
check 'producer success 15 min or more escalates with URI and run URL',
      [o.error, o.reason], [Autobump::Escalate, "bundle asset missing: #{asset} (#{RUN})"]
check 'the escalation is marked as a bundle decision', o.result&.values_at('bundle', 'exit', 'uris'), [true, 3, [asset]]

two = [producer(minutes_ago: 90, run: "#{RUN}0"), producer(minutes_ago: 20)]
o = fetch(log_404(asset), status(bundle(producers: two)))
check 'the latest producer run is the one named', o.reason, "bundle asset missing: #{asset} (#{RUN})"
two = [producer(minutes_ago: 90, run: "#{RUN}0"), producer(minutes_ago: 3)]
check 'a later stage finished under 15 min ago still defers',
      fetch(log_404(asset), status(bundle(producers: two))).error, Autobump::Abort

running = [producer, producer(status: 'in_progress', conclusion: nil, minutes_ago: nil, run: "#{RUN}9")]
o = fetch(log_404(asset), status(bundle(producers: running)))
check 'a ready bundle whose later stage still runs defers naming that run',
      [o.error, o.reason], [Autobump::Abort, "bundle pending: #{REPO}@#{TAG} (#{RUN}9)"]

page = "https://github.com/#{REPO}/releases/tag/#{TAG}"
{ 'a failed producer' => [producer(conclusion: 'failure')],
  'a cancelled producer' => [producer(conclusion: 'cancelled')],
  'a missing producer' => [producer(status: 'missing', conclusion: nil, minutes_ago: nil)],
  'one failed stage beside a success' => [producer, producer(conclusion: 'failure')],
  'no producer at all' => [] }.each do |name, producers|
  o = fetch(log_404(asset), status(bundle(producers: producers)))
  check "#{name} escalates without success evidence",
        [o.error, o.reason], [Autobump::Escalate, "bundle asset missing, no successful producer: #{asset} (#{page})"]
end
o = fetch(log_404(asset), status(bundle(producers: [producer(conclusion: 'skipped')])))
check 'a skipped producer is no success evidence', o.error, Autobump::Escalate

# a success whose completion time the snapshot lacks cannot be timed against the settle window
o = fetch(log_404(asset), status(bundle(producers: [producer(minutes_ago: nil)])))
check 'a success without completed_at defers',
      [o.error, o.reason], [Autobump::Abort, "bundle pending: #{REPO}@#{TAG} (#{RUN}); producer completion time unknown"]
o = fetch(log_404(asset), status(bundle(producers: [producer(minutes_ago: nil), producer(conclusion: 'failure')])))
check 'a success without completed_at beside a failure still escalates', o.error, Autobump::Escalate

# two bundles on one release: the decision is the union of their evidence, not array order
early = bundle(id: 'node_modules', producers: [producer(minutes_ago: 60, run: "#{RUN}1")])
late = bundle(id: 'web', producers: [producer(minutes_ago: 5, run: "#{RUN}2")])
both = [[early, late], [late, early]].map do |pair|
  o = fetch(log_404(asset), status(*pair))
  [o.error, o.reason, o.result&.fetch('bundles')]
end
check 'two bundles on one release judge the same in either order', both.uniq.length, 1
check 'two bundles on one release: the latest producer decides', both.first[0..1],
      [Autobump::Abort, "bundle pending: #{REPO}@#{TAG} (#{RUN}2); producer finished under 15 min ago"]
failed = bundle(id: 'web', producers: [producer(conclusion: 'failure')])
both = [[early, failed], [failed, early]].map { |pair| fetch(log_404(asset), status(*pair)).reason }
check 'two bundles on one release: a failed one escalates in either order', both,
      ["bundle asset missing, no successful producer: #{asset} (#{page})"] * 2
pending = bundle(id: 'web', state: 'pending', producers: [producer(status: 'in_progress', conclusion: nil, minutes_ago: nil, run: "#{RUN}2")])
both = [[early, pending], [pending, early]].map { |pair| fetch(log_404(asset), status(*pair)).reason }
check 'two bundles on one release: a pending one defers in either order', both,
      ["bundle pending: #{REPO}@#{TAG} (#{RUN}2)"] * 2

# multi-asset bundle: the asset that did download says nothing; the missing one is named
web = "#{RELEASE}/deepseek-harness-0.2.0-rc.2-web.tar.xz"
o = fetch(log_saved(asset) + log_404(web), status(bundle))
check 'multi-asset: only the missing asset is named', [o.error, o.reason], [Autobump::Escalate, "bundle asset missing: #{web} (#{RUN})"]
o = fetch(log_404(asset, web), status(bundle(state: 'pending')))
check 'multi-asset: both missing while pending defer once', [o.error, o.result&.fetch('uris')], [Autobump::Abort, [asset, web]]
other = bundle(id: 'vendor', repo: 'gentoo-zh/gentoo-deps', tag: 'deepseek-harness-0.2.0_rc2', state: 'pending')
vendor = 'https://github.com/gentoo-zh/gentoo-deps/releases/download/deepseek-harness-0.2.0_rc2/vendor.tar.xz'
o = fetch(log_404(asset, vendor), status(bundle, other))
check 'two bundles: the escalating one wins over the pending one',
      [o.error, o.reason, o.result&.fetch('bundles')&.length], [Autobump::Escalate, "bundle asset missing: #{asset} (#{RUN})", 2]

# mixed: a source 404 is a real defect whatever the bundle is doing
source = 'https://github.com/deepseek/harness/releases/download/v0.2.0-rc.2/harness-0.2.0-rc.2.tar.gz'
o = fetch(log_404(source, asset), status(bundle(state: 'pending')))
check 'source 404 beside a pending bundle 404 escalates as before',
      [o.error, o.reason, o.result], [Autobump::Escalate, 'upstream distfile for 1.1 is missing (404/403), not a slow mirror', nil]
o = fetch(log_404("https://github.com/#{REPO}/releases/download/0.2.0-rc.1/old.tar.xz"), status(bundle(state: 'pending')))
check 'a 404 on another tag of the bundle repo escalates as before', [o.error, o.result], [Autobump::Escalate, nil]
# only a 404 is the contract's bundle exception: a 403 on a covered URI is access, not a build
o = fetch(">>> Downloading '#{asset}'\nERROR 403: Forbidden.\n", status(bundle(state: 'pending')))
check 'a covered 403 escalates as before',
      [o.error, o.reason, o.result], [Autobump::Escalate, 'upstream distfile for 1.1 is missing (404/403), not a slow mirror', nil]
o = fetch(log_404(web) + ">>> Downloading '#{asset}'\nERROR 403: Forbidden.\n", status(bundle(state: 'pending')))
check 'a covered 403 beside a covered 404 escalates as before', [o.error, o.result], [Autobump::Escalate, nil]

# unchanged paths
mirror_then_saved = <<~LOG
  >>> Downloading 'https://distfiles.gentoo.org/distfiles/23/x.tar.zst'
  ERROR 404: Not Found.
  #{log_saved(asset).chomp}
  >>> Downloading 'https://upstream.example/pkg-1.1.tar.gz'
  Connecting to upstream.example|10.255.255.1|:443... failed: Connection timed out.
LOG
o = fetch(mirror_then_saved, status(bundle(state: 'pending')))
check 'mirror 404 then success defers as a slow mirror, not a bundle',
      [o.error, o.reason, o.result], [Autobump::Abort, 'fetch/manifest for 1.1 failed (mirror unreachable or too slow)', nil]
o = fetch(log_404(asset) + "Permission denied\n", status(bundle(state: 'pending')))
check 'a local failure is not hidden behind a bundle defer', [o.error, o.result], [Autobump::Escalate, nil]
o = fetch(log_404(asset), status(bundle(state: 'pending')), code: 124)
check 'an op-timeout defers as before', [o.error, o.result], [Autobump::Abort, nil]

# no flag: the same covered 404 escalates exactly as it did before --bundle-status
o = fetch(log_404(asset), nil)
check 'without a snapshot a bundle 404 escalates as before',
      [o.error, o.reason, o.result, o.stdout.include?('result:')],
      [Autobump::Escalate, 'upstream distfile for 1.1 is missing (404/403), not a slow mirror', nil, false]

# --- classify: a covered deps URL skips the early 404 defer and reaches the fetch
def classify(ebuild, bundles, pkg: 'demo-cat/deps', old_pv: '1.0.0', newver: '1.0.1')
  Dir.mktmpdir('autobump-bundle-classify-') do |dir|
    pkgdir = File.join(dir, pkg)
    FileUtils.mkdir_p(pkgdir)
    old = File.join(pkgdir, "#{File.basename(pkg)}-#{old_pv}.ebuild")
    File.write(old, ebuild)
    evidence = Autobump::Evidence.new('bundle-classify')
    got = nil
    with_stubs(dir) do
      got = Autobump::Classify.new(cfg: nil, pkg: pkg, old_ebuild: old, old_pv: old_pv, newver: newver,
                                   evidence: evidence, bundles: bundles).run.escalations
    rescue Autobump::Abort => e
      got = e.message
    end
    FileUtils.rm_rf(evidence.dir)
    got
  end
end

deps = <<~EBUILD
  EAPI=8
  SRC_URI="
  \thttps://example.invalid/${P}.tar.gz
  \thttps://github.com/gentoo-zh-drafts/deps/releases/download/v${PV}/${P}-vendor.tar.xz
  "
  KEYWORDS="~amd64"
EBUILD
deps_status = status(bundle(repo: 'gentoo-zh-drafts/deps', tag: 'v1.0.1'), package: 'demo-cat/deps', version: '1.0.1')
wrong = 'https://github.com/gentoo-zh-drafts/deps/releases/download/v1.0.1/deps-1.0.1-vendor.tar.xz'
check 'without a snapshot the deps 404 defers at classify', classify(deps, nil),
      "per-version deps artifact missing (HTTP 404): #{wrong}"
check 'wrong filename: classify lets the covered URL through', classify(deps, deps_status), []
o = fetch(log_404(wrong), deps_status)
check 'wrong filename: the fetch escalates naming the asset',
      [o.error, o.reason], [Autobump::Escalate, "bundle asset missing: #{wrong} (#{RUN})"]
check 'a snapshot for another repo does not bypass classify',
      classify(deps, status(bundle(tag: 'v1.0.1'), package: 'demo-cat/deps', version: '1.0.1')),
      "per-version deps artifact missing (HTTP 404): #{wrong}"

my_pv = <<~EBUILD
  EAPI=8
  MY_PV="${PV/_rc/-rc.}"
  SRC_URI="https://github.com/#{REPO}/releases/download/${MY_PV}/${PN}-${MY_PV}-node_modules.tar.zst"
  KEYWORDS="~amd64"
EBUILD
check 'a MY_PV bundle URL passes classify and is judged at the fetch',
      classify(my_pv, s, pkg: PKG, old_pv: '0.2.0_rc1', newver: VER), []

# --- the command line
def refuses(args)
  Autobump::CLI.parse(args)
  false
rescue SystemExit
  true
end
check '--bundle-status takes a file', Autobump::CLI.parse(%w[cat/pkg 1.2.3 --bundle-status b.json])[:bundle_status], 'b.json'
check '--bundle-status without a file is refused', refuses(%w[cat/pkg 1.2.3 --bundle-status]), true
check 'no --bundle-status leaves it unset', Autobump::CLI.parse(%w[cat/pkg 1.2.3])[:bundle_status], nil

# the engine end to end on the golden fixture: the snapshot is loaded after the target is
# known, a bad one stops the run, and a covered deps URL is never probed at classify
def engine(snapshot_path)
  bindir = File.join(File.dirname(snapshot_path), 'bin')
  FileUtils.mkdir_p(bindir)
  File.write(File.join(bindir, 'curl'), "#!/bin/sh\nprintf 404\n")
  File.chmod(0o755, File.join(bindir, 'curl'))
  env = { 'AUTOBUMP_REPO' => File.join(__dir__, 'fixtures'), 'PATH' => "#{bindir}:#{ENV['PATH']}" }
  out = IO.popen(env, ['ruby', File.join(__dir__, '..', 'bin', 'autobump'), 'demo-cat/deps', '1.0.1', '--check',
                       '--bundle-status', snapshot_path], err: %i[child out], &:read)
  [$?.exitstatus, out]
end
Dir.mktmpdir('autobump-bundle-engine-') do |dir|
  path = File.join(dir, 'bundles.json')
  File.write(path, JSON.generate(snapshot([bundle(repo: 'gentoo-zh-drafts/deps', tag: 'v1.0.1')],
                                          package: 'demo-cat/deps', version: '1.0.1')))
  code, out = engine(path)
  check 'engine: a covered deps URL is left to the fetch', [code, out.include?('deps artifact check skipped (bundle')], [0, true]
  code, out = engine(File.join(dir, 'absent.json'))
  check 'engine: a missing snapshot stops the run', [code, out.include?('!! --bundle-status: no such file')], [2, true]
  File.write(path, JSON.generate(snapshot([bundle], package: 'demo-cat/deps', version: '1.0.2')))
  code, out = engine(path)
  check 'engine: a snapshot without this target stops the run', [code, out.include?('no target for demo-cat/deps 1.0.1')], [2, true]
end

puts '----'
puts "bundle_status: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
