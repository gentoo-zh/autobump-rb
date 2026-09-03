# frozen_string_literal: true
require 'fileutils'
require 'timeout'
require 'uri'
require 'open-uri'
module Autobump
  # Stage 4: fetch old artifacts, create the new ebuild, fetch + manifest.
  # An unreachable/slow mirror is transient -> Abort (exit 2) so the sweep retries.
  # A file upstream does not have (404/403) is permanent -> Escalate (exit 3).
  class Distfiles
    # Local, permanent reasons `ebuild manifest` can fail, as portage words them. Kept narrow:
    # anything not listed here stays a transient defer, because a wrong guess here turns a slow
    # mirror into a manual bump.
    LOCAL_FAILURES = [
      /Permission denied/,
      /error sourcing ebuild/,
      /No space left on device/,
      /command not found/
    ].freeze

    # The offending line, or nil when nothing local went wrong.
    def self.local_failure(out)
      out.lines.map(&:chomp).reverse.find { |l| LOCAL_FAILURES.any? { |re| l =~ re } }&.strip
    end

    REWRITE_FETCH_TIMEOUT = 120
    REWRITE_MAX_BYTES = 8 * 1024 * 1024

    MISSING = /ERROR 40[34]:|\b40[34]\b[^\n]*\b(Not Found|Forbidden|File not found)\b/i

    # portage's fetch log, split into the ">>> Downloading '<uri>'" blocks it writes per URI.
    # Anything before the first block belongs to no URI.
    def self.download_blocks(out)
      blocks = []
      out.each_line do |line|
        if (uri = line[/^>>> Downloading '([^']+)'/, 1])
          blocks << [uri, +'']
        elsif !blocks.empty?
          blocks.last[1] << line
        end
      end
      blocks
    end

    # A distfile is only missing upstream when a URI the EBUILD names says so. Portage probes
    # GENTOO_MIRRORS first and a fresh distfile is never on them, so their routine 404 would
    # otherwise turn every transient upstream failure into a permanent escalation.
    def self.upstream_missing?(out, mirrors)
      hosts = mirrors.to_s.split.filter_map { |m| URI.parse(m).host rescue nil }
      blocks = download_blocks(out)
      return out.match?(MISSING) if blocks.empty? # no per-URI structure to judge by
      # a URI portage went back to and got the file from says nothing about the file missing
      fetched = blocks.select { |_uri, text| text.match?(/\bsaved \[|\bDownloaded:/) }.map(&:first)
      blocks.any? do |uri, text|
        host = (URI.parse(uri).host rescue nil)
        !hosts.include?(host) && !fetched.include?(uri) && text.match?(MISSING)
      end
    end

    def initialize(ctx) = (@c = ctx)
    def run
      c = @c; cfg = c.cfg
      Dir.chdir(c.pkgdir) do
        old = File.basename(c.old_ebuild); neweb = File.basename(c.new_ebuild)
        _, ok = c.sh('ebuild', old, 'fetch', sudo: true, timeout: cfg.op_timeout)
        unless ok
          # OLD distfile only feeds the tree/surface diff. An upstream that keeps only its
          # latest release (+ RESTRICT=mirror) 404s on the old one -- don't defer the whole
          # bump for that. Flag it: the diff stage skips, and the new fetch (the manifest
          # below) + the emerge build gate + a PR flagged "no diff" for human review still
          # vouch for the new version.
          Log.log 'OLD distfile unavailable (upstream keeps only latest?); tree/surface diff skipped, relying on the build gate + PR review'
          c.old_distfile_missing = true
        end
        # bash's cp is unchecked: on failure the new ebuild is absent and the next
        # manifest fails -> Abort. Swallow SystemCallError so it does not surface as
        # an uncaught exit 1 that skips cleanup and orphans the branch.
        begin
          FileUtils.cp(old, neweb)
          c.copied_ebuild = true # cleanup may delete it; nothing else may
        rescue SystemCallError => e
          raise Abort, "could not create new ebuild: #{e.message}"
        end
        rewrite(neweb) if c.rewrite_var
        out, ok, code = c.sh('ebuild', neweb, 'manifest', sudo: true, timeout: cfg.op_timeout)
        c.evidence.write('fetch.log', out)
        unless ok
          puts out.lines.last(5).join
          # the op-timeout firing says nothing about the file, only about how long it took
          raise Abort, "fetch/manifest timed out (>#{cfg.op_timeout}s); deferring" if code == 124
          # portage says "Couldn't download" for both a 404 and an unreachable mirror, so split on
          # what the fetcher reported per URI: 404/403 means the file is not there, which no number
          # of retries fixes -- deferring it just files "will retry automatically" every day and
          # hides the real defect (wrong SRC_URI path, stale pin, artifact never published).
          # Anything else (timeout, connection reset, 5xx) is worth another sweep.
          # Match wget's own line ("ERROR 404: Not Found." / "ERROR 404: File not found.") as well
          # as a bare status line, because the reason text differs per server.
          if Distfiles.upstream_missing?(out, `portageq envvar GENTOO_MIRRORS 2>/dev/null`)
            raise Escalate.new("upstream distfile for #{c.newver} is missing (404/403), not a slow mirror",
                               c.evidence.dir)
          end
          # not every other failure is transient: an unreadable ebuild, a missing eclass or a
          # full disk never fixes itself, and deferring one files "will retry automatically"
          # every sweep while the real line sits in a run log nobody opens.
          if (local = Distfiles.local_failure(out))
            raise Escalate.new("fetch/manifest for #{c.newver} failed locally: #{local}", c.evidence.dir)
          end
          raise Abort, "fetch/manifest for #{c.newver} failed (mirror unreachable or too slow)"
        end
        system(*[cfg.sudo, 'chown', "#{`id -un`.strip}:#{`id -gn`.strip}", 'Manifest'].reject { |x| x.nil? || x.empty? })
      end
      Log.ok 'distfiles fetched, Manifest regenerated'
    end

    private

    # Fetch and apply the optional opaque token only after copying the selected ebuild.
    # The rewritten SRC_URI is therefore what Manifest fetches; a wrong token fails at
    # that fetch gate, while a source/vendor mismatch that still fetches reaches BuildTest.
    def rewrite(neweb)
      c = @c
      url = Rewrite.expand_url(c.rewrite_url, c.newver)
      # per-read timeouts do not bound a slow drip, and the document is a release index of a
      # few kilobytes: cap the whole read in time and in size.
      document = begin
        Timeout.timeout(REWRITE_FETCH_TIMEOUT) do
          URI.open(url, open_timeout: 30, read_timeout: 30) { |io| io.read(REWRITE_MAX_BYTES) }
        end
      rescue StandardError => e
        raise Abort, "could not fetch rewrite source #{url}: #{e.message}"
      end

      value = Rewrite.extract_value(document, regex: Rewrite.expand_regex(c.rewrite_regex, c.newver))
      unless value
        raise Abort, "rewrite source #{url} gave no non-empty capture group 1 for " \
                     "#{c.rewrite_regex.inspect} (the release document may not be published yet)"
      end

      text = begin
        File.read(neweb, encoding: 'UTF-8').scrub
      rescue SystemCallError, ArgumentError => e
        raise Abort, "could not read copied ebuild for rewrite from #{url}: #{e.message}"
      end
      result = Rewrite.rewrite_assignment(text, c.rewrite_var, value)
      unless result.text
        raise Abort, "rewrite source #{url} could not rewrite #{c.rewrite_var}: #{result.reason}"
      end

      c.evidence.write('rewrite.txt',
                       "variable=#{c.rewrite_var}\nold_value=#{result.old_value}\n" \
                       "new_value=#{value}\nsource_url=#{url}\n")
      unless result.changed
        # source_pin no longer guards this variable, so an unchanged token is nobody's
        # responsibility any more: the regex selected the previous release's value, or
        # upstream genuinely reused it. Either way a human decides, not the copy.
        raise Escalate.new("rewrite value for #{c.rewrite_var} is unchanged at #{result.old_value} " \
                           "for #{c.newver}; check the selector or bump by hand", c.evidence.dir)
      end

      begin
        File.write(neweb, result.text, encoding: 'UTF-8')
      rescue SystemCallError, ArgumentError => e
        raise Abort, "could not write copied ebuild for rewrite from #{url}: #{e.message}"
      end
      Log.ok "rewrote #{c.rewrite_var} from #{url}"
    end
  end
end
