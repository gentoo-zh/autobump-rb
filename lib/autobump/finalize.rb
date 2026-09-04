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
    HOMEPAGE_USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                          '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'

    # Homepage checks are browser-facing: some sites reject pkgcheck's HEAD/bot request while
    # serving the same page to a normal browser. Keep source-archive checks on curl's default
    # GET so a browser-only response cannot hide a fetch failure.
    def self.flagged_url_records(scan_output, pkg)
      current = nil
      scan_output.each_line.with_object([]) do |line, records|
        if (header = line[/\A(\S+\/\S+)[[:space:]]*\z/, 1])
          current = header
        end
        # the default reporter groups findings under a header; another one prints
        # "cat/pn-version: Check: ..." per line. Take the package from whichever is there.
        mine = current == pkg || line.start_with?("#{pkg}-")
        next unless mine && line =~ /DeadUrl|RedirectedUrl/

        field = line[/\b([A-Z_]+):[[:space:]]/, 1]
        records.concat(line.scan(URL_IN_TEXT).map do |u|
          [u.sub(/[)\],.;:'"]+\z/, ''), field]
        end)
      end.uniq
    end

    # pkgcheck reports the package's URLs, not the bump's. A finding on a field this commit did
    # not touch is pre-existing - the same scan reports it for the version already in the tree -
    # and blocking the bump on it asks the wrong person at the wrong time.
    def self.records_this_bump_touched(records, touched)
      records.select { |_url, field| field.nil? || touched.include?(field) }
    end

    # A version-only copy changes no field: the version is normalised away before the two texts
    # are compared. A diff cannot answer this - a rename shows the whole file as added, which is
    # how a homepage nobody touched came back as "changed by this bump".
    def self.fields_changed(old_text, new_text, old_pv, newver)
      before = assignments(old_text)
      after = assignments(new_text.gsub(newver, old_pv))
      after.reject { |name, value| before[name] == value }.keys
    end

    def self.assignments(text)
      text.lines.filter_map do |line|
        match = line.chomp.match(/\A[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)\z/)
        [match[1], match[2].strip] if match
      end.to_h
    end

    def self.flagged_urls(scan_output, pkg)
      flagged_url_records(scan_output, pkg).map(&:first).uniq
    end

    def self.url_recheck_command(url, homepage: false)
      args = ['curl', '-sL', '--max-time', '20']
      args.concat(['-A', HOMEPAGE_USER_AGENT]) if homepage
      args + ['-o', '/dev/null', '-w', '%{http_code}', url]
    end

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


    private

    def dead_url_recheck
      c = @c; repo = c.cfg.repo
      net = Dir.chdir(repo) { `pkgcheck scan --commits --net 2>&1`.scrub }
      c.evidence.write('pkgcheck-net.txt', net)
      records = Finalize.flagged_url_records(net, c.pkg)
      old_path = "#{c.pkg}/#{File.basename(c.old_ebuild)}"
      old_text = `git -C #{repo.shellescape} show HEAD~1:#{old_path.shellescape} 2>/dev/null`
      changed = Finalize.fields_changed(old_text, File.read(c.new_ebuild), c.old_pv, c.newver)
      records = Finalize.records_this_bump_touched(records, changed)
      urls = records.map(&:first).uniq
      return Log.log('pkgcheck URL findings are on fields this bump did not touch') if urls.empty?

      # array-form curl: a URL with '&' (query strings) must not be split by the shell
      recheck = urls.map do |u|
        homepage = records.any? { |url, field| url == u && field == 'HOMEPAGE' }
        code = IO.popen(Finalize.url_recheck_command(u, homepage: homepage), &:read).strip
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
