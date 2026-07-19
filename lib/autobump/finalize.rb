# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Stage 7: finalize + QA + commit. Drop the old ebuild, regen the Manifest, gate on
  # the pkgcheck findings the bump INTRODUCED (baseline subtracted), commit with the bot
  # identity, then a net pkgcheck with URL recheck. git/pkgdev calls use array form (no
  # shell), so paths need no quoting.
  class Finalize
    def initialize(ctx) = (@c = ctx)

    # baseline (preflight) and after (here) MUST use the identical cwd + pipeline so
    # the later `comm -13` compares like with like: both run in $REPO with the same
    # `sed | sort -u`, so only findings the bump introduced survive the subtraction.
    def self.pkgcheck_scan(repo, pkg)
      Dir.chdir(repo) do
        `pkgcheck scan #{pkg.shellescape} 2>/dev/null | sed -E 's/version [^:]+: //' | sort -u`
      end
    end

    # Order ebuild paths oldest-first by PORTAGE version (vercmp), so a caller can slice the
    # newest N. portage's own comparator (always present on a Gentoo host) ranks _alpha/_beta/
    # _pre/_rc as OLDER than the release; `sort -V` gets that backwards. Falls back to `sort -V`
    # only if portage's python is somehow unavailable.
    SORT_BY_VERSION_PY = <<~'PY'
      import sys, os, functools
      from portage.versions import vercmp
      pn = sys.argv[1]; paths = sys.argv[2:]
      def ver(p): return os.path.basename(p)[len(pn) + 1:-7]  # strip "pn-" prefix and ".ebuild"
      paths.sort(key=functools.cmp_to_key(lambda a, b: vercmp(ver(a), ver(b)) or 0))
      sys.stdout.write("\n".join(paths))
    PY
    def self.sort_by_version(paths, pn)
      return paths if paths.size < 2
      out = IO.popen(['python3', '-c', SORT_BY_VERSION_PY, pn, *paths], err: File::NULL, &:read)
      return out.split("\n") if $?.success? && !out.strip.empty?
      # fallback: the engine's usual sort -V ordering (correct except for _pre/_rc prereleases)
      IO.popen(['sort', '-V'], 'r+') { |io| io.puts(paths); io.close_write; io.read }.split("\n").reject(&:empty?)
    end

    def run
      c = @c; cfg = c.cfg; repo = cfg.repo; nul = File::NULL
      # bash removes the smoke accept_keywords file at stage-7 top unconditionally
      # (632); mirror that so a successful bump does not leak one file per run.
      system(*[cfg.sudo, 'rm', '-f', "/etc/portage/package.accept_keywords/autobump-#{c.pn}"]
               .reject { |x| x.nil? || x.empty? }, err: nul)
      # keep_old (per-package): how the OLD ebuild(s) are handled when adding the new one.
      #   absent/false -> drop the replaced version (default);
      #   integer N>=1 -> keep the N most-recent release versions, git-rm anything older;
      #   0 (or true)  -> keep ALL prior versions (unbounded).
      # Whatever ebuilds remain, `pkgdev manifest` below keeps their DIST entries automatically:
      # stage 4 already regenerated the Manifest with the new + old ebuilds present (distfiles.rb:31),
      # so it succeeds with no refetch even when an old distfile is no longer fetchable upstream.
      if c.keep_old.is_a?(Integer) && c.keep_old.positive?
        # the new ebuild already exists (stage 4); keep the N highest releases, drop the rest.
        # Order by PORTAGE version (vercmp), NOT `sort -V`: GNU sort -V ranks _alpha/_beta/_pre/_rc
        # as NEWER than the release, but portage/pkgdev rank them OLDER -- so sort -V could keep a
        # stale _rc and git-rm the newest real release.
        ebuilds = `ls #{c.pkgdir.shellescape}/*.ebuild 2>/dev/null | grep -vE -- '-9{4,}'`
                  .lines.map(&:strip).reject(&:empty?)
        releases = Finalize.sort_by_version(ebuilds, c.pn)
        (releases[0...-c.keep_old] || []).each { |e| system('git', '-C', repo, 'rm', '-q', e) }
      elsif !c.keep_old
        system('git', '-C', repo, 'rm', '-q', c.old_ebuild)
      end
      # keep_old == 0 (or true) -> keep ALL prior versions: neither branch runs, nothing is dropped
      # regen the Manifest: drops the removed version's DIST entry when dropped, keeps both when
      # keep_old (distfiles all local, no refetch). capture the output so a failure carries reason.
      mout = Dir.chdir(c.pkgdir) { IO.popen(['pkgdev', 'manifest'], err: %i[child out], &:read) }
      raise Abort, "manifest regen failed: #{mout.strip.lines.last(6).join.strip}" unless $?.success?
      system('git', '-C', repo, 'add', c.pkgdir)
      c.evidence.write('pkgcheck-after.txt', Finalize.pkgcheck_scan(repo, c.pkg))
      base = c.evidence.path('pkgcheck-baseline.txt'); after = c.evidence.path('pkgcheck-after.txt')
      new = `comm -13 #{base.shellescape} #{after.shellescape}`
      c.evidence.write('pkgcheck-new.txt', new)
      unless new.strip.empty?
        puts new
        raise Escalate.new('pkgcheck findings introduced by the bump', c.evidence.dir)
      end
      env = {}
      if cfg.bot_email && !cfg.bot_email.empty?
        name = cfg.bot_name || 'gentoo-zh autobump'
        env = { 'GIT_AUTHOR_NAME' => name, 'GIT_AUTHOR_EMAIL' => cfg.bot_email,
                'GIT_COMMITTER_NAME' => name, 'GIT_COMMITTER_EMAIL' => cfg.bot_email }
      end
      committed = Dir.chdir(repo) { system(env, 'pkgdev', 'commit', '--scan', 'false', '--signoff') }
      raise Abort, 'pkgdev commit failed' unless committed
      c.armed = false # commit is made; an interrupt now must NOT discard it
      Log.ok "committed: #{`git -C #{repo.shellescape} log -1 --format=%s`.strip}"
      dead_url_recheck
    end

    private

    def dead_url_recheck
      c = @c; repo = c.cfg.repo
      net = Dir.chdir(repo) { `pkgcheck scan --commits --net 2>&1`.scrub }
      c.evidence.write('pkgcheck-net.txt', net)
      flagged = net.lines.select { |l| l =~ /DeadUrl|RedirectedUrl/ && l.include?(c.pn) }
      return if flagged.empty?
      # re-verify only the URLs in the PN-context window (bash: `grep -A1 "$PN"`), not
      # the whole scan, so an unrelated DeadUrl elsewhere can't force a false escalate.
      lines = net.lines
      window = +''
      lines.each_index { |i| window << lines[i] << (lines[i + 1] || '') if lines[i].include?(c.pn) }
      urls = window.scan(%r{https://[^ \r\n]+}).uniq
      # array-form curl: a URL with '&' (query strings) must not be split by the shell
      recheck = urls.map do |u|
        code = IO.popen(['curl', '-sL', '--max-time', '20', '-o', '/dev/null', '-w', '%{http_code}', u], &:read).strip
        code = '000' if code.empty? # curl couldn't connect at all -> network-inconclusive marker
        "#{u} -> #{code}"
      end
      c.evidence.write('url-recheck.txt', recheck.join("\n") + "\n")
      bad = recheck.reject { |l| l.end_with?(' -> 200') }
      return Log.log('pkgcheck URL findings were transient (all URLs 200 on recheck)') if bad.empty?
      puts bad.join("\n")
      # a 000/timeout/5xx is network-inconclusive, not a confirmed dead URL: defer (retry next
      # sweep) rather than permanently escalate a bump that already built + committed clean, on
      # a mirror/CDN blip. Only a stable 4xx is a real DeadUrl -> escalate.
      raise Abort, 'URL recheck inconclusive (network/5xx); deferring' if bad.all? { |l| l =~ %r{ -> (000|5[0-9][0-9])\z} }
      raise Escalate.new('URL findings persist after recheck', c.evidence.dir)
    end
  end
end
