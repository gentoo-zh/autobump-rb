# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Stage 3: preflight. Clean-tree gate, sync master from the CANONICAL remote, drop a
  # stale branch, create the bump branch, re-read OLD_EBUILD from the synced tree (a dev
  # box may lag), pkgcheck baseline. git calls use array form (no shell), so repo/branch
  # paths need no quoting.
  class Preflight
    def initialize(ctx) = (@c = ctx)
    def run
      c = @c; cfg = c.cfg; repo = cfg.repo; sr = cfg.sync_remote; nul = File::NULL
      # untracked files are unrelated work (preserve); only TRACKED mods block,
      # except scripts/ and docs/ which are this tooling, never part of a bump.
      dirty = `git -C #{repo.shellescape} status --porcelain --untracked-files=no`.lines
              .reject { |l| l =~ %r{ (scripts|docs)/} }.any? { |l| !l.strip.empty? }
      raise Abort, 'working tree has tracked modifications' if dirty
      raise Abort, "git fetch #{sr} failed" \
        unless system('git', '-C', repo, 'fetch', sr, out: nul, err: nul)
      unless system('git', '-C', repo, 'checkout', '-q', 'master', err: nul)
        raise Abort, 'cannot checkout master - commit/stash your scripts/ or docs/ changes first ' \
                     '(the tool switches to master, where those files do not exist)'
      end
      raise Abort, "master is not a fast-forward of #{sr}/master (diverged?)" \
        unless system('git', '-C', repo, 'merge', '-q', '--ff-only', "#{sr}/master")
      if system('git', '-C', repo, 'rev-parse', '--verify', '-q', c.branch, out: nul)
        Log.log "dropping stale branch #{c.branch} from a prior attempt"
        raise Abort, "branch #{c.branch} exists and could not be removed" \
          unless system('git', '-C', repo, 'branch', '-qD', c.branch, err: nul)
      end
      raise Abort, "cannot create #{c.branch}" \
        unless system('git', '-C', repo, 'checkout', '-qb', c.branch)
      c.armed = true # branch exists; an interrupt/failure must now run cleanup (disarmed after commit)
      Log.ok "branch #{c.branch} off synced master"
      # Re-read OLD_EBUILD from the now-synced tree (stage-1 read the working tree,
      # which on a dev box may lag canonical master). Same pipeline as locate.
      c.old_ebuild = Version.release_ebuilds(repo, c.pkgdir).last.to_s
      raise Abort, "no release ebuild in #{c.pkgdir} after sync" if c.old_ebuild.empty?
      c.old_pvr = File.basename(c.old_ebuild, '.ebuild').sub(/\A#{Regexp.escape(c.pn)}-/, '')
      c.old_pv  = c.old_pvr.sub(/-r[0-9]+\z/, '')
      raise Abort, "already at #{c.newver} on synced master" if c.old_pv == c.newver
      # re-apply classify's strict-newer guard against the SYNCED old_pv: stage-1 read a
      # possibly-lagging dev-box tree, but synced master may already be PAST the target, in
      # which case proceeding would silently open a version-downgrade PR.
      raise Abort, "synced master is at #{c.old_pv}, newer than target #{c.newver} (would downgrade)" \
        unless Version.newer?(c.newver, c.old_pv)
      raise Abort, "#{c.new_ebuild} already exists on synced master" if File.exist?(c.new_ebuild)
      Log.log "current updated after sync: -> #{c.old_pvr}" if c.old_pvr != c.old_pvr_presync
      # bash 318: run in $REPO, identical sed+sort -u pipeline, so the later locale
      # `comm -13` sees both files sorted the same way (ruby's bytewise .sort could differ)
      c.evidence.write('pkgcheck-baseline.txt', Finalize.pkgcheck_scan(repo, c.pkg))
    end
  end
end
