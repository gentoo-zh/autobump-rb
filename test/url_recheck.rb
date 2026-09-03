#!/usr/bin/env ruby
# frozen_string_literal: true
# Test which URLs a pkgcheck --net scan hands to the recheck: only the URL findings under this
# package's header, and only the URL itself. Hermetic. Run: ruby test/url_recheck.rb
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

SCAN = <<~OUT
  app-editors/cursor
    DeadUrl: version 3.19.7: SRC_URI: 404 Client Error: Not Found for url: https://downloads.example/x/deb/amd64/deb/app_3.19.7_amd64.deb
    MissingRemoteId: version 3.19.7: github: missing (inferred from URI 'https://github.com/Acme/cursor')
  net-misc/other
    DeadUrl: version 1.0: HOMEPAGE: 404 Client Error for url: https://other.example/gone
OUT

check 'a URL finding under this package is rechecked, whatever the URL spells',
      Autobump::Finalize.flagged_urls(SCAN, 'app-editors/cursor'),
      %w[https://downloads.example/x/deb/amd64/deb/app_3.19.7_amd64.deb]

check "another package's dead URL is not this bump's problem",
      Autobump::Finalize.flagged_urls(SCAN, 'app-misc/unrelated'), []

check 'a non-URL finding is not a URL to recheck',
      Autobump::Finalize.flagged_urls(SCAN, 'app-editors/cursor').any? { |u| u.include?('Acme') }, false

redirected = <<~OUT
  dev-util/x
    RedirectedUrl: version 1.0: SRC_URI: permanently redirected: https://a.example/f.tar.gz -> https://b.example/f.tar.gz.
OUT
check 'a redirect names both URLs, without the sentence punctuation',
      Autobump::Finalize.flagged_urls(redirected, 'dev-util/x'),
      %w[https://a.example/f.tar.gz https://b.example/f.tar.gz]

V = Autobump::Finalize.method(:recheck_verdict)
check 'all 200 clears the finding', V.call(['https://a -> 200', 'https://b -> 200']), :clean
check 'a stable 404 is a dead URL', V.call(['https://a -> 200', 'https://b -> 404']), :dead
check 'a 000 defers instead of escalating', V.call(['https://a -> 000']), :inconclusive
check 'a 503 defers too', V.call(['https://a -> 503']), :inconclusive
check 'a 404 next to a 000 is still dead', V.call(['https://a -> 000', 'https://b -> 404']), :dead

one_line = "app-editors/cursor-3.19.7: DeadUrl: SRC_URI: 404 Client Error for url: https://downloads.example/app.deb\n"
check 'a reporter that prints one line per finding is read too',
      Autobump::Finalize.flagged_urls(one_line, 'app-editors/cursor'),
      %w[https://downloads.example/app.deb]

puts '----'
puts $fail.zero? ? 'url_recheck: all passed' : "url_recheck: #{$fail} failed"
exit($fail.zero? ? 0 : 1)
