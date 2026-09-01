# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Stage 2: deterministic classification. Each check yields an escalation note
  # (evidence for the judge) or a transient defer. No LLM here; nothing edits
  # RDEPEND/IUSE from a guess. An escalation means "this is not mechanically safe
  # -> exit 3 for a judge"; a defer waits for a transient prerequisite. Every
  # branch here is pinned by test/decisions.tsv.
  class Classify
    Result = Struct.new(:escalations, :multiarch, :gui, :keywords_line, keyword_init: true)

    def initialize(cfg:, pkg:, old_ebuild:, old_pv:, newver:, evidence:, rewrite_var: nil)
      @cfg, @pkg, @old_ebuild = cfg, pkg, old_ebuild
      @cat, @pn = pkg.split('/', 2)
      @old_pv, @newver, @ev, @rewrite_var = old_pv, newver, evidence, rewrite_var
      # tolerate non-UTF-8 bytes: scrub so a later regex/scan can't raise an uncaught
      # ArgumentError (invalid byte sequence) that would exit 1, off the 0/2/3 contract.
      @text = File.read(old_ebuild, encoding: 'UTF-8').scrub
      @pkgdir = File.dirname(old_ebuild)
    end

    def run
      esc = []
      (rw = rewrite_assignment) and esc << rw
      esc << "target looks like a prerelease: #{@newver}" if prerelease?
      (m = major_jump)        and esc << m
      (nn = not_newer)        and esc << nn
      (ps = parallel_slots)   and esc << ps
      (p = pins)              and esc << p
      (sp = source_pin)       and esc << sp
      defer = deps_artifact
      (pt = applied_patches)  and esc << pt
      (hc = hackport_cabal)   and esc << hc
      # a 404 alongside a real escalation is evidence for the human, not a reason to retry
      esc << defer if defer && !esc.empty?
      @ev.write('classify.txt', keywords_line ? "#{keywords_line}\n" : '')
      @ev.write('escalations.txt', esc.join("\n") + "\n") unless esc.empty?
      @ev.write('defer.txt', "#{defer}\n") if defer && esc.empty?
      ma = multiarch?
      gui = gui?
      Log.log 'multi-arch KEYWORDS: non-amd64 will be marked untested, PR will be draft' if ma
      # A missing project-generated bundle is temporal, not a safety judgment, so it defers --
      # but only when nothing else escalated: a package that is unsafe for another reason must
      # reach a human now instead of retrying until the sweep's cap.
      raise Abort, defer if defer && esc.empty?
      Result.new(escalations: esc, multiarch: ma, gui: gui, keywords_line: keywords_line)
    end

    private
    # This is deliberately the same parser Distfiles uses to make the actual edit:
    # classification rejects precisely the input the later rewrite would refuse, before
    # preflight creates a branch.
    def rewrite_assignment
      return unless @rewrite_var
      Rewrite.rewrite_assignment(@text, @rewrite_var, Rewrite::VALIDATION_VALUE).reason
    end

    def prerelease?
      return false unless @newver =~ /(alpha|beta|rc[0-9]*|pre|nightly|dev)([._-]|$)/i
      Dir.children(@pkgdir).none? { |f| f =~ /_(alpha|beta|rc|pre)/ }
    end

    def major_jump
      date = /\A20[0-9]{6}([._-][0-9]+)*\z/
      if @old_pv =~ date && @newver =~ date
        if @newver.split(/[._-]/, 2).first.to_i < @old_pv.split(/[._-]/, 2).first.to_i
          "date version went backwards: #{@old_pv} -> #{@newver}"
        end
      elsif @old_pv.split('.', 2).first != @newver.split('.', 2).first
        "major component change: #{@old_pv} -> #{@newver}"
      end
    end

    # version must sort strictly newer. a same-major downgrade, or an nvchecker
    # version-format reparse that yields a lower version, still fetches + builds
    # against the older source, so nothing downstream catches it -- it would open a
    # version-downgrade PR that looks like a routine bump. sort -V is the same
    # comparator locate uses to pick the current ebuild.
    def not_newer
      top = `printf '%s\\n%s\\n' #{@old_pv.shellescape} #{@newver.shellescape} | sort -V | tail -1`.strip
      "target version is not newer than current: #{@old_pv} -> #{@newver}" unless top == @newver
    end

    # two release lines in one package dir, separated by SLOT: games-arcade/osu-lazer-bin keeps a
    # "stable" line fetching ${PV}-lazer and a "tachyon" line fetching ${PV}-tachyon. locate picks
    # the highest version in the dir, which can belong to the OTHER line, and the version-only copy
    # then fetches a distfile upstream never published. The version alone does not say which line a
    # new release belongs to, so a human has to pick the template.
    def parallel_slots
      slots = Dir.glob(File.join(@pkgdir, '*.ebuild')).reject { |f| f =~ /-9{4,}\.ebuild\z/ }
                 .filter_map { |f| File.read(f, encoding: 'UTF-8').scrub[/^[[:space:]]*SLOT=.*/] }
                 .map { |l| l.strip.sub(/\A.*SLOT=/, '').delete('"\'') }.uniq
      return nil if slots.length < 2
      "package has parallel release lines by SLOT (#{slots.sort.join(', ')}) - " \
        'the template ebuild cannot be chosen by version alone, copy the one from the matching line'
    end

    # pin/coupled vars (GIT_CRATES, a commit/tag/version pin) are RECORDED as evidence but do not
    # escalate on their own: autobump copies the old ebuild verbatim, so these lines are unchanged
    # by the bump. A pin that is actually stale surfaces downstream -- its per-version vendor tarball
    # 404s (distfiles defers) or the emerge fails on the source/vendor mismatch (build gate escalates).
    # So a package whose pins are stable (codex: byte-identical crates bundle every version) is
    # correctly mechanical instead of a false escalate. Whole comment lines are skipped either way.
    def pins
      hits = @text.lines.each_with_index
                  .reject { |l, _| l =~ /^[[:space:]]*#/ }
                  .select { |l, _| l =~ /GIT_CRATES|_COMMIT=|_TAG=|[A-Z_]+_VER=/ }
      return if hits.empty?
      @ev.write('pins.txt', hits.map { |l, i| "#{i + 1}:#{l}" }.join) # bash `grep -n` N:content format
      nil # record only; the 404 (distfiles) and emerge (build) gates decide staleness
    end

    # a source ebuild pinned to a specific commit/tag with NO per-version vendor bundle:
    # a version-only copy keeps the OLD pin, so distfiles + emerge succeed against stale
    # source and only the advisory smoke notices. deps_artifact catches the vendor-bundle
    # case (its URL 404s); this catches the no-bundle case that nothing else guards.
    # comment lines are excluded, matching pins()'s "comment-only pins don't escalate".
    def source_pin
      # strip each line at the first '#' before scanning: a _COMMIT=/_TAG= that lives only
      # in an INLINE comment must not escalate. Apply this masking to source_pin ONLY --
      # pins() below strips whole comment lines but keeps inline ones on purpose (it only
      # records evidence, never escalates), so it must not get this stricter masking.
      # a pin the rewrite spec updates every bump is not a stale pin: exclude that one
      # variable, and escalate only if some OTHER pin is left unhandled.
      pinned = @text.lines.map { |l| l.sub(/#.*/, '') }
                    .select { |l| l =~ /_COMMIT=|_TAG=/ }
                    .reject { |l| @rewrite_var && l =~ /\A[[:space:]]*#{Regexp.escape(@rewrite_var.to_s)}=/ }
      return nil if pinned.empty?
      return nil if @text.scan(%r{https://[^ "\r\n]+}).any? { |u| u =~ /(-deps|-vendor|-crates|node_modules)\.tar\./ }
      'ebuild pins a source commit/tag but has no per-version vendor artifact - verify the pin was bumped for the new version, do not version-copy'
    end

    def deps_artifact
      # grep -oE is line-based; Ruby [^ "] would include \n and grab across lines,
      # so exclude newline/CR to match grep's per-line extraction exactly.
      url = @text.scan(%r{https://[^ "\r\n]+}).find { |u| u =~ /(-deps|-vendor|-crates|node_modules)\.tar\./ }
      return nil unless url
      t = url.gsub('${P}', "#{@pn}-#{@newver}").gsub('${PV}', @newver).gsub('${PN}', @pn)
      t = t.gsub(Regexp.new(@old_pv.gsub('.', '\\.')), @newver)
      code = `curl -sIL --max-time 30 -o /dev/null -w '%{http_code}' #{t.shellescape} 2>/dev/null`.strip
      code = '000' if code.empty?
      case code
      when '200' then (Log.ok("deps artifact exists: #{t}"); nil)
      when '404' then "per-version deps artifact missing (HTTP 404): #{t}"
      # inconclusive (network) -> fetch stage re-checks; not a terminal defer
      else (Log.log("deps artifact check inconclusive (HTTP #{code}, network?): #{t}"); nil)
      end
    end

    def applied_patches
      patches = Dir.glob(File.join(@pkgdir, 'files', '*.patch')).sort
      return nil if patches.empty?
      @ev.write('patches.txt', patches.join("\n") + "\n")
      if @text =~ /eapply|epatch|PATCHES[+]?=|FILESDIR.*\.patch/
        'files/ patches applied by the ebuild - re-apply must be verified'
      end
    end

    # hackport/haskell-cabal ebuilds: the dep bounds, ghc/cabal floors and hackage revision come
    # from the upstream .cabal (via hackport), not the ebuild, so a version-only copy silently
    # keeps stale bounds. Escalate to hackport/a human.
    def hackport_cabal
      return nil unless @text =~ /^[[:space:]]*inherit\b.*\bhaskell-cabal\b/
      'hackport/haskell-cabal ebuild: dep bounds + hackage revision come from the upstream .cabal, not the ebuild - regenerate with hackport, do not version-copy'
    end

    def keywords_line
      @keywords_line ||= @text.lines.find { |l| l =~ /^[[:space:]]*KEYWORDS=/ }&.chomp
    end

    def multiarch? = (kl = keywords_line) ? kl.scan(/~[a-z0-9]+/).length > 1 : false
    def gui? = @text.lines.any? { |l| l =~ /^[[:space:]]*inherit.*(desktop|xdg)/ }
  end
end
