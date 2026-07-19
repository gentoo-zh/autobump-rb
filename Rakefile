# frozen_string_literal: true
task default: %i[syntax decisions pr_body heavy_dep keep_old]

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
