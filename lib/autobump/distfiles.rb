# frozen_string_literal: true
require 'fileutils'
module Autobump
  # Stage 4: fetch old artifacts, create the new ebuild, fetch + manifest.
  # An unreachable/slow mirror is transient -> Abort (exit 2) so the sweep retries.
  # A file upstream does not have (404/403) is permanent -> Escalate (exit 3).
  class Distfiles
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
        rescue SystemCallError => e
          raise Abort, "could not create new ebuild: #{e.message}"
        end
        out, ok = c.sh('ebuild', neweb, 'manifest', sudo: true, timeout: cfg.op_timeout)
        c.evidence.write('fetch.log', out)
        unless ok
          puts out.lines.last(5).join
          # portage says "Couldn't download" for both a 404 and an unreachable mirror, so split on
          # what the fetcher reported per URI: 404/403 means the file is not there, which no number
          # of retries fixes -- deferring it just files "will retry automatically" every day and
          # hides the real defect (wrong SRC_URI path, stale pin, artifact never published).
          # Anything else (timeout, connection reset, 5xx) is worth another sweep.
          # Match wget's own line ("ERROR 404: Not Found." / "ERROR 404: File not found.") as well
          # as a bare status line, because the reason text differs per server.
          if out =~ /ERROR 40[34]:/ || out =~ /\b40[34]\b[^\n]*\b(Not Found|Forbidden|File not found)\b/i
            raise Escalate.new("upstream distfile for #{c.newver} is missing (404/403), not a slow mirror",
                               c.evidence.dir)
          end
          raise Abort, "fetch/manifest for #{c.newver} failed (mirror unreachable or too slow)"
        end
        system(*[cfg.sudo, 'chown', "#{`id -un`.strip}:#{`id -gn`.strip}", 'Manifest'].reject { |x| x.nil? || x.empty? })
      end
      Log.ok 'distfiles fetched, Manifest regenerated'
    end
  end
end
