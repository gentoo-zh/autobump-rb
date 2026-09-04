# frozen_string_literal: true
task default: %i[syntax sweep decisions pr_body heavy_dep cli_flags payload_diff rewrite gui_probe build_dispatch fetch_failure sh_timeout distfiles_outcome deps_artifact_url dynamic_source_pin preflight_guards version_compare url_recheck remote_pick gates]

desc 'ruby -c on all sources'
task :syntax do
  Dir['lib/**/*.rb', 'bin/*'].each { |f| sh "ruby -c #{f}" }
end

desc 'golden decision test (hermetic, uses test/fixtures)'
task :decisions do
  sh 'bash test/decisions.sh'
end

desc 'golden test for the PR body (hermetic)'
task :pr_body do
  sh 'ruby test/pr_body.rb'
end

desc 'heavy-dependency pre-check parser (hermetic)'
task :heavy_dep do
  sh 'ruby test/heavy_dep.rb'
end

desc 'what the command line asks for (hermetic)'
task :cli_flags do
  sh 'ruby test/cli_flags.rb'
end

desc 'payload path-diff fold rules (hermetic)'
task :payload_diff do
  sh 'ruby test/payload_diff.rb'
end

desc 'opaque upstream-token rewrite parsing and refusal rules (hermetic)'
task :rewrite do
  sh 'ruby test/rewrite.rb'
end

desc 'GUI launch outcome classification (hermetic)'
task :gui_probe do
  sh 'ruby test/gui_probe.rb'
end

desc 'build-test payload/install dispatch (hermetic)'
task :build_dispatch do
  sh 'ruby test/build_dispatch.rb'
end

desc 'fetch/manifest local-failure classification (hermetic)'
task :fetch_failure do
  sh 'ruby test/fetch_failure.rb'
end


desc 'which pkgcheck URLs get rechecked (hermetic)'
task :url_recheck do
  sh 'ruby test/url_recheck.rb'
end

desc 'which remote master is synced from (hermetic)'
task :remote_pick do
  sh 'ruby test/remote_pick.rb'
end

desc 'the elog and pkgcheck release gates (hermetic)'
task :gates do
  sh 'ruby test/gates.rb'
end

desc 'what a failed fetch/manifest turns into (hermetic)'
task :distfiles_outcome do
  sh 'ruby test/distfiles_outcome.rb'
end

desc 'the guards preflight applies after syncing master (hermetic)'
task :preflight_guards do
  sh 'ruby test/preflight_guards.rb'
end

desc 'version ordering, without portage (hermetic)'
task :version_compare do
  sh 'ruby test/version_compare.rb'
end

desc 'the command helper and its timeout (hermetic)'
task :sh_timeout do
  sh 'ruby test/sh_timeout.rb'
end

desc "the overlay driver's tests; needs AUTOBUMP_OVERLAY pointing at an overlay checkout"
task :sweep do
  if ENV['AUTOBUMP_OVERLAY'].to_s.empty?
    puts 'sweep: skipped (set AUTOBUMP_OVERLAY to an overlay checkout)'
    next
  end
  Dir['test/sweep/*.py'].sort.each { |f| sh "python3 #{f}" }
end

desc 'the vendor-artifact URL a version bump probes (hermetic)'
task :deps_artifact_url do
  sh 'ruby test/deps_artifact_url.rb'
end

desc 'which source pins a version copy updates by itself (hermetic)'
task :dynamic_source_pin do
  sh 'ruby test/dynamic_source_pin.rb'
end
