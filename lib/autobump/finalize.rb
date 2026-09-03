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
    # Portage's order, not `sort -V`: sort -V ranks _alpha/_beta/_pre/_rc above the release, so
    # it would keep a stale rc and git-rm the newest real release.
    def self.sort_by_version(paths, pn)
      paths.sort { |a, b| Version.compare(pv_of(a, pn), pv_of(b, pn)) }
    end

    def self.pv_of(path, pn)
      File.basename(path, '.ebuild').sub(/\A#{Regexp.escape(pn)}-/, '')
    end

    # Which ebuilds the bump retires. keep_old is the number of releases to keep (the new one
    # included), false to keep only the new one, and true or 0 to keep every prior version.
    def self.retire(releases, keep_old, old_ebuild)
      return releases[0...-keep_old] || [] if keep_old.is_a?(Integer) && keep_old.positive?
      return [old_ebuild] unless keep_old

      []
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
      # the new ebuild exists but is not committed yet, so this lists the directory rather than
      # what git tracks
      ebuilds = Dir.glob(File.join(c.pkgdir, '*.ebuild')).reject { |f| f =~ /-9{4,}\.ebuild\z/ }
      releases = Finalize.sort_by_version(ebuilds, c.pn)
      Finalize.retire(releases, c.keep_old, c.old_ebuild).each { |e| system('git', '-C', repo, 'rm', '-q', e) }
      # keep_old == 0 (or true) -> keep ALL prior versions: neither branch runs, nothing is dropped
      # regen the Manifest: drops the removed version's DIST entry when dropped, keeps both when
      # keep_old (distfiles all local, no refetch). capture the output so a failure carries reason.
      mout = Dir.chdir(c.pkgdir) { IO.popen(['pkgdev', 'manifest'], err: %i[child out], &:read) }
      raise Abort, "manifest regen failed: #{mout.strip.lines.last(6).join.strip}" unless $?.success?
      system('git', '-C', repo, 'add', c.pkgdir)
      c.evidence.write('pkgcheck-after.txt', Finalize.pkgcheck_scan(repo, c.pkg))
      base = c.evidence.path('pkgcheck-baseline.txt'); after = c.evidence.path('pkgcheck-after.txt')
      new = Finalize.introduced(File.read(base), File.read(after))
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

    # pkgcheck lists findings under a "cat/pn" header, and a finding line need not name the
    # package at all -- a DeadUrl says only the URL. Select by the header, and take URLs from
    # the URL findings alone: a MissingRemoteId line quotes a URI in parentheses, and rechecking
    # `https://github.com/Acme/etcd')` escalates a bump whose URLs are all fine.
    URL_IN_TEXT = %r{https?://[^\s'"<>]+}

    # The findings the bump added: what the after-scan reports and the baseline did not. A
    # finding the bump REMOVED is not a reason to escalate.
    def self.introduced(baseline, after)
      before = baseline.lines.map(&:chomp).to_h { |l| [l, true] }
      added = after.lines.map(&:chomp).reject { |l| l.empty? || before[l] }
      added.empty? ? '' : added.join("\n") + "\n"
    end

    # What the recheck proves. A 000 or 5xx says the network was unhappy, not that the URL is
    # dead, so it defers rather than permanently escalating a bump that built and committed
    # clean; only a stable 4xx is a confirmed DeadUrl.
    def self.recheck_verdict(recheck)
      bad = recheck.reject { |l| l.end_with?(' -> 200') }
      return :clean if bad.empty?
      bad.all? { |l| l =~ / -> (000|5[0-9][0-9])\z/ } ? :inconclusive : :dead
    end

    def self.flagged_urls(scan_output, pkg)
      current = nil
      scan_output.each_line.with_object([]) do |line, urls|
        if (header = line[/\A(\S+\/\S+)[[:space:]]*\z/, 1])
          current = header
        end
        # the default reporter groups findings under a header; another one prints
        # "cat/pn-version: Check: ..." per line. Take the package from whichever is there.
        mine = current == pkg || line.start_with?("#{pkg}-")
        next unless mine && line =~ /DeadUrl|RedirectedUrl/

        urls.concat(line.scan(URL_IN_TEXT).map { |u| u.sub(/[)\],.;:'"]+\z/, '') })
      end.uniq
    end

    private

    def dead_url_recheck
      c = @c; repo = c.cfg.repo
      net = Dir.chdir(repo) { `pkgcheck scan --commits --net 2>&1`.scrub }
      c.evidence.write('pkgcheck-net.txt', net)
      urls = Finalize.flagged_urls(net, c.pkg)
      return if urls.empty?
      # array-form curl: a URL with '&' (query strings) must not be split by the shell
      recheck = urls.map do |u|
        code = IO.popen(['curl', '-sL', '--max-time', '20', '-o', '/dev/null', '-w', '%{http_code}', u], &:read).strip
        code = '000' if code.empty? # curl couldn't connect at all -> network-inconclusive marker
        "#{u} -> #{code}"
      end
      c.evidence.write('url-recheck.txt', recheck.join("\n") + "\n")
      case Finalize.recheck_verdict(recheck)
      when :clean then return Log.log('pkgcheck URL findings were transient (all URLs 200 on recheck)')
      when :inconclusive
        puts recheck.reject { |l| l.end_with?(' -> 200') }.join("\n")
        raise Abort, 'URL recheck inconclusive (network/5xx); deferring'
      else
        puts recheck.reject { |l| l.end_with?(' -> 200') }.join("\n")
        raise Escalate.new('URL findings persist after recheck', c.evidence.dir)
      end
    end
  end
end
