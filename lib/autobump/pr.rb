# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Stage 8: PR. Push the branch (bail if a review PR is already open on it), open a
  # PR that cc's the package maintainers (parsed from metadata.xml), marks multi-arch
  # bumps draft, and notes GUI uncertainty.
  class PR
    MDMETA_AWK = <<~'AWK'
      /<maintainer/{e="";n=""}
      /<email>/{t=$0; gsub(/.*<email>[[:space:]]*|[[:space:]]*<\/email>.*/,"",t); e=t}
      /<name>/ {t=$0; gsub(/.*<name>[[:space:]]*|[[:space:]]*<\/name>.*/,"",t);  n=t}
      /<\/maintainer>/{print e "\t" n}
    AWK

    QUERY_TRIES = 3

    # The PR numbers open for this head, or [nil, why] when gh could not answer. A blip in the
    # API is not worth a bump that is already built and committed, so ask again before giving up.
    def self.open_pr_for(upstream_repo, head)
      last = ''
      QUERY_TRIES.times do |attempt|
        out = IO.popen(['gh', 'pr', 'list', '--repo', upstream_repo, '--state', 'open',
                        '--head', head, '--json', 'number', '--jq', '.[].number'],
                       err: %i[child out], &:read)
        return [out, nil] if $?&.success?

        last = out.to_s.strip.lines.last.to_s.strip
        sleep(2 * (attempt + 1))
      end
      [nil, last.empty? ? 'gh failed' : last]
    end

    # A multi-arch bump is opened as a draft: only amd64 was built here, so the other
    # keywords are untested until a human says otherwise.
    def self.create_args(repo:, head:, title:, body_file:, multiarch:)
      args = ['gh', 'pr', 'create', '--repo', repo, '--base', 'master',
              '--head', head, '--title', title, '--body-file', body_file]
      args << '--draft' if multiarch
      args
    end

    def initialize(ctx) = (@c = ctx)

    def run
      c = @c; cfg = c.cfg
      unless c.pr
        Log.log "committed on #{c.branch} - review, then: git push -u #{cfg.push_remote} #{c.branch} && gh pr create ..."
        return
      end
      owner = `git -C #{cfg.repo.shellescape} remote get-url #{cfg.push_remote.shellescape}`.strip
              .sub(/\.git$/, '').sub(%r{/$}, '').sub(%r{.*[:/]([^/]+)/[^/]+$}, '\1')
      head = owner == cfg.upstream_repo.split('/').first ? c.branch : "#{owner}:#{c.branch}"
      # a reviewer may have pushed fixups onto an open PR for this branch; do not clobber.
      # Ask about this branch (--head), not about the newest 30 open PRs gh lists by default.
      open, reason = PR.open_pr_for(cfg.upstream_repo, head)
      # a failed query proves nothing; pushing on it would force over the branch it was
      # supposed to protect
      raise Abort, "cannot tell whether #{c.branch} has an open PR: #{reason}; not pushing" if open.nil?
      unless open.strip.empty?
        Log.log "an open PR already exists for #{c.branch} - not pushing (would clobber review)"
        return
      end
      # plain --force, not --force-with-lease: a brand-new topic branch has no remote-tracking
      # ref, so bare --force-with-lease refuses with "stale info" and no PR is ever opened (this
      # is the common case -- every bump branch is new, and a fresh CI clone never fetched it).
      # The open-PR guard above already protects a branch under active review; a leftover branch
      # from an aborted prior attempt (no open PR) is safe to overwrite.
      # print the commit's file list before pushing. A rejected push names only the offending
      # path (GitHub's workflow-scope guard does exactly that), and the evidence dir is gone
      # with the CI container, so this is the only record of what the commit actually carried.
      puts `git -C #{cfg.repo.shellescape} show --oneline --stat HEAD`
      raise Abort, 'push failed' \
        unless system('git', '-C', cfg.repo, 'push', '-u', '--force', cfg.push_remote, c.branch)
      body = c.evidence.path('pr-body.md')
      File.write(body, pr_body)
      subj = `git -C #{cfg.repo.shellescape} log -1 --format=%s`.strip
      args = PR.create_args(repo: cfg.upstream_repo, head: head, title: subj, body_file: body,
                            multiarch: c.multiarch)
      raise Abort, 'gh pr create failed' unless system(*args)
      Log.ok 'PR opened'
    end

    private

    # PR body: terse checklist, English so every contributor can read it. Only the gates
    # that actually passed get a tick and only real caveats get a warning line -- no "nothing
    # changed" prose. The title is the gentoo `cat/pkg: ...` form.
    def pr_body
      c = @c
      lines = ["**`#{c.pkg}`** #{c.old_pvr} → #{c.newver} — nvchecker bump", '',
               '- [x] emerge build + install',
               '- [x] `pkgcheck scan --commits --net` clean',
               "- smoke: #{c.smoke}"]
      lines << rewrite_line if rewrite_line
      lines += diff_lines
      meta = []
      meta << "Closes ##{c.issue}" if c.issue
      ccs = maintainer_ccs
      meta << "cc #{ccs}" unless ccs.empty?
      lines += ['', meta.join(' · ')] unless meta.empty?
      lines.join("\n") + "\n"
    end

    # A rewritten variable is an opaque token a reviewer cannot check by eye, so the PR
    # carries where it came from and what it replaced.
    def rewrite_line
      f = @c.evidence.path('rewrite.txt')
      return nil unless File.exist?(f)
      v = File.read(f).lines.to_h { |l| l.chomp.split('=', 2) }
      "- rewrote `#{v['variable']}` #{v['old_value']} → #{v['new_value']} from #{v['source_url']}"
    end

    # The old→new diff. Both added and removed reflect the change, so show both in a collapsed
    # block (added = new files / new build options; removed = the breakage-risk side). Three
    # cases: old distfile gone -> can't compare; compared with no change; or there is a diff.
    # Version-renames and bundler content-hash asset churn are filtered out upstream -- only
    # STRUCTURAL changes reach here; the asset-churn count is noted so it is not silently hidden.
    def diff_lines
      c = @c
      return ['', "Warning: no old→new diff: upstream keeps only its latest release, so the old distfile (#{c.old_pvr}) 404s — check the payload before merging"] if c.old_distfile_missing
      kind = c.payload ? 'payload' : 'build-option surface'
      af   = c.payload ? 'tree-added-real.txt'   : 'surface-added.txt'
      rf   = c.payload ? 'tree-removed-real.txt' : 'surface-removed.txt'
      return ["- diff vs #{c.old_pvr}: #{kind} not compared (unpack needed build deps); the emerge build gate vouches"] \
        unless File.exist?(c.evidence.path(af))
      added = read_ev(af); removed = read_ev(rf)
      churn = read_ev('tree-churn-count.txt').first.to_i
      note = churn.positive? ? " · #{churn} bundled assets rebuilt" : ''
      if added.empty? && removed.empty?
        empty = c.payload ? "no structural payload changes#{note}" : 'no build-option surface changes'
        return ["- diff vs #{c.old_pvr}: #{empty}"]
      end
      cap = 120
      # every removal, then as many additions as fit: a removal is the side that can break the
      # package, so it must not sort past the cap behind a wall of additions.
      shown_added = added.first([cap - removed.size, 0].max)
      entries = shown_added.map { |p| [p, '+'] } + removed.map { |p| [p, '-'] }
      # sort by path so related changes sit together: a rename shows -old/+new adjacent,
      # and same-directory changes cluster instead of scattering across an all-+/all-- split.
      entries.sort_by! { |p, _| p }
      diff = entries.map { |p, s| "#{s} #{p}" }
      diff << "… #{added.size - shown_added.size} more additions" if shown_added.size < added.size
      ['', "**#{kind} diff vs #{c.old_pvr}** (+#{added.size}/-#{removed.size})#{note}",
       '<details><summary>show</summary>', '', '```diff', *diff, '```', '</details>']
    end

    def read_ev(name)
      p = @c.evidence.path(name)
      File.exist?(p) ? File.readlines(p).map(&:chomp).reject(&:empty?) : []
    end

    # metadata.xml maintainers -> GitHub @handles so the owners are cc'd. Best-effort.
    def maintainer_ccs
      c = @c; mx = "#{c.pkgdir}/metadata.xml"
      return '' unless File.exist?(mx)
      out = []
      up = c.cfg.upstream_repo.shellescape
      `awk '#{MDMETA_AWK}' #{mx.shellescape}`.each_line do |ln|
        em, nm = ln.chomp.split("\t", 2)
        em ||= ''; nm ||= ''
        next if (em + nm).empty?
        login = ''
        login = `gh api -X GET repos/#{up}/commits -f author=#{em.shellescape} -f per_page=1 --jq '.[0].author.login // empty' 2>/dev/null`.strip unless em.empty?
        if login.empty? && !nm.empty?
          login = `gh api -X GET repos/#{up}/commits -f path=#{c.pkg.shellescape} -f per_page=50 2>/dev/null | jq -r --arg n #{Shellwords.escape(nm)} 'map(select(.commit.author.name==$n).author.login)|map(select(.!=null))|first // empty' 2>/dev/null`.strip
        end
        out << (!login.empty? ? "@#{login}" : (!em.empty? ? em : nm))
      end
      out.join(' ')
    end
  end
end
