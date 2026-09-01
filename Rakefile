# frozen_string_literal: true
task default: %i[syntax decisions pr_body heavy_dep keep_old payload_diff rewrite gui_probe build_dispatch fetch_failure]

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

desc 'keep_old flag wiring (hermetic)'
task :keep_old do
  sh 'ruby test/keep_old.rb'
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
