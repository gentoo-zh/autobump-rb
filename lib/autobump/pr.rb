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
      # a reviewer may have pushed fixups onto an open PR for this branch; do not clobber
      jq = ".[] | select(.headRefName==\"#{c.branch}\" and .headRepositoryOwner.login==\"#{owner}\") | .number"
      open = IO.popen(['gh', 'pr', 'list', '--repo', cfg.upstream_repo, '--state', 'open',
                       '--json', 'number,headRefName,headRepositoryOwner', '--jq', jq],
                      err: File::NULL, &:read)
      unless open.strip.empty?
        Log.log "an open PR already exists for #{c.branch} - not pushing (would clobber review)"
        return
      end
      # plain --force, not --force-with-lease: a brand-new topic branch has no remote-tracking
      # ref, so bare --force-with-lease refuses with "stale info" and no PR is ever opened (this
      # is the common case -- every bump branch is new, and a fresh CI clone never fetched it).
      # The open-PR guard above already protects a branch under active review; a leftover branch
      # from an aborted prior attempt (no open PR) is safe to overwrite.
      raise Abort, 'push failed' \
        unless system('git', '-C', cfg.repo, 'push', '-u', '--force', cfg.push_remote, c.branch)
      body = c.evidence.path('pr-body.md')
      File.write(body, pr_body)
      subj = `git -C #{cfg.repo.shellescape} log -1 --format=%s`.strip
      args = ['gh', 'pr', 'create', '--repo', cfg.upstream_repo, '--base', 'master',
              '--head', head, '--title', subj, '--body-file', body]
      args << '--draft' if c.multiarch
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
      lines += diff_lines
      meta = []
      meta << "Closes ##{c.issue}" if c.issue
      ccs = maintainer_ccs
      meta << "cc #{ccs}" unless ccs.empty?
      lines += ['', meta.join(' · ')] unless meta.empty?
      lines.join("\n") + "\n"
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
      # sort by path so related changes sit together: a rename shows -old/+new adjacent,
      # and same-directory changes cluster instead of scattering across an all-+/all-- split.
      entries = added.map { |p| [p, '+'] } + removed.map { |p| [p, '-'] }
      entries.sort_by! { |p, _| p }
      diff = entries.first(cap).map { |p, s| "#{s} #{p}" }
      diff << "… #{entries.size - cap} more" if entries.size > cap
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
