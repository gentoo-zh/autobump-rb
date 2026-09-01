# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Stage 5: artifact diff. Prebuilt payload -> unpack both and diff the file tree
  # (a removed path is dangerous unless it is a version-embedded rename). Source ->
  # diff the build-option surface (cmake/meson/autotools/cargo); a changed surface
  # may need a USE flag or dependency.
  #
  # The find/grep/sed/awk pipelines run as a single bash heredoc, so the surface extraction
  # is one block instead of a chain of Ruby shell-outs.
  class ArtifactDiff
    SURFACE_SH = <<~'SH'
      top=$($SUDO find "$1" -maxdepth 1 -mindepth 1 -type d | head -1)
      [ -n "$top" ] || top="$1"
      {
          $SUDO find "$top" -maxdepth 3 \( -name CMakeLists.txt -o -name '*.cmake' \) \
              -exec grep -hoE '(option|cmake_dependent_option|find_package|pkg_check_modules)[[:space:]]*\([[:space:]]*[A-Za-z0-9_.-]+' {} + 2>/dev/null \
              | sed -E 's/[[:space:]]*\([[:space:]]*/:/' | sed 's/^/cmake-/'
          $SUDO find "$top" -maxdepth 2 \( -name meson_options.txt -o -name meson.options \) \
              -exec grep -hoE "option[[:space:]]*\([[:space:]]*'[a-z0-9_-]+" {} + 2>/dev/null \
              | sed -E "s/option[[:space:]]*\([[:space:]]*'/meson-option:/"
          $SUDO find "$top" -maxdepth 2 -name meson.build \
              -exec grep -hoE "dependency[[:space:]]*\([[:space:]]*'[a-z0-9_.-]+" {} + 2>/dev/null \
              | sed -E "s/dependency[[:space:]]*\([[:space:]]*'/meson-dep:/"
          $SUDO find "$top" -maxdepth 2 \( -name configure.ac -o -name configure.in \) \
              -exec grep -hoE '(AC_ARG_ENABLE|AC_ARG_WITH|PKG_CHECK_MODULES)\(\[?[A-Za-z0-9_-]+' {} + 2>/dev/null \
              | sed -E 's/\(\[?/:/' | sed 's/^/ac-/'
          $SUDO find "$top" -maxdepth 2 -name Cargo.toml \
              -exec awk '/^\[features\]/{f=1;next}/^\[/{f=0}f&&/^[a-z0-9_-]+[[:space:]]*=/{print "cargo-feature:"$1}' {} + 2>/dev/null
      } | sort -u > "$2"
    SH

    # Placeholder for the version or hash run blanked out by pairing rules (2) and (3).
    VER_HOLE = '<v>'
    HASH_RUN = /(?<=[-.])[A-Za-z0-9_-]{7,}(?=\.[A-Za-z0-9]+\z)/

    # Fold benign churn out of a payload path diff so only structural add/remove is left.
    # Pure -- no filesystem, no Context -- so test/payload_diff.rb can pin every rule.
    # Returns [real_removed, real_added, churned_count].
    #
    # (1) A version-embedded rename driven by the package version: OLD_PV -> NEWVER.
    # (2) A bundler content-hash rename: a filename with seven or more ASCII letters, digits,
    #     `_`, or `-` after `.` or `-` before its final extension, carrying a digit or mixed
    #     case so a lowercase word is not mistaken for a hash, e.g.
    #     foo-<hashA>.js -> foo-<hashB>.js. Fold a removal only with exactly one addition in
    #     the same directory whose basename matches after blanking the hash; otherwise an
    #     upstream removal remains structural. Fold hash-bearing additions on their own: they
    #     cannot escalate, and omitting them keeps churn meaningful. Pairing catches rehashes
    #     outside the old directory list without letting a directory hide an unreplaced file.
    # (3) A bundled artifact on its own version stream, which (1) cannot pair because the
    #     number in the filename is not the package version -- jetbrains-toolbox ships
    #     bin/lib/agent-client-0.8.6635.jar and moves it to agent-client-0.8.6806.jar while
    #     the package goes 3.6.2.85969 -> 3.6.3.86383, so all 26 jars looked structural.
    #     Deliberately narrow: blank the dotted-numeric run in the BASENAME only and require
    #     the directory to be identical, so a moved or renamed directory still escalates
    #     (`find -type f` lists no directory entries, so a renamed dir shows up as its files
    #     changing dirname, which this rule does not pair). Fold only on an exact 1:1 match;
    #     with two candidates for one key a real removal could hide behind a coincidence.
    def self.fold_benign(removed, added, old_pv, newver)
      real_removed = removed.reject { |p| added.include?(p.gsub(old_pv, newver)) }
      real_added   = added.reject   { |p| removed.include?(p.gsub(newver, old_pv)) }
      churned = 0

      # (2) a content-hash rename. A lowercase word is a name, not a hash: require a digit or
      #     mixed case, so a renamed `org.example.desktop` stays structural while
      #     `kernel.C5XtPPRo.js` folds. Hash-bearing additions fold on their own -- an
      #     addition cannot escalate, and folding it keeps the churn count meaningful.
      hashed = lambda do |p|
        run = File.basename(p)[HASH_RUN]
        !run.nil? && (run.match?(/\d/) || (run.match?(/[a-z]/) && run.match?(/[A-Z]/)))
      end
      real_removed, real_added, folded =
        fold_pairs(real_removed, real_added, drop_added: true, candidate: hashed,
                   key: ->(p) { "#{File.dirname(p)}/#{File.basename(p).sub(HASH_RUN, VER_HOLE)}" })
      churned += folded

      # (3) an independently-versioned bundled artifact: jetbrains-toolbox moves
      #     bin/lib/agent-client-0.8.6635.jar to 0.8.6806 while the package goes
      #     3.6.2.85969 -> 3.6.3.86383, so (1) cannot pair it by the package version.
      real_removed, real_added, folded =
        fold_pairs(real_removed, real_added, candidate: ->(_p) { true },
                   key: ->(p) { "#{File.dirname(p)}/#{File.basename(p).gsub(/\d+(?:\.\d+)+/, VER_HOLE)}" })
      churned += folded

      # (4) a renumbered bundler chunk: app-editors/cursor moved dist/657.js to dist/61.js and
      #     app-office/siyuan-bin stage/build/export/805.js to 806.js. Narrow on purpose -- the
      #     whole basename must be an integer and the extension a script or style one, so a
      #     dropped icon16.png next to an added icon32.png stays structural.
      real_removed, real_added, folded =
        fold_pairs(real_removed, real_added,
                   candidate: ->(p) { File.basename(p) =~ /\A\d+\.(js|mjs|cjs|css)\z/ },
                   key: ->(p) { "#{File.dirname(p)}/#{VER_HOLE}#{File.extname(p)}" })
      churned += folded

      [real_removed, real_added, churned]
    end

    # The shared safety rule behind (2), (3) and (4): a removal folds only when exactly one
    # addition carries the same key, so an unreplaced or ambiguous removal always survives.
    # `drop_added` additionally discards every candidate addition, which only rule (2) wants.
    # Returns [removed, added, folded_count].
    def self.fold_pairs(removed, added, candidate:, key:, drop_added: false)
      rm_by_key = removed.select(&candidate).group_by(&key)
      ad_by_key = added.select(&candidate).group_by(&key)
      paired = rm_by_key.keys.select { |k| rm_by_key[k].size == 1 && ad_by_key[k]&.size == 1 }
                        .to_h { |k| [k, true] }
      folds = ->(p) { candidate.call(p) && paired[key.call(p)] }
      kept_removed = removed.reject(&folds)
      kept_added = drop_added ? added.reject(&candidate) : added.reject(&folds)
      [kept_removed, kept_added,
       (removed.size - kept_removed.size) + (added.size - kept_added.size)]
    end

    def initialize(ctx) = (@c = ctx)

    def run
      c = @c
      c.payload = payload?
      if c.payload
        payload_diff
      elsif (wd_old = tree_of(File.basename(c.old_ebuild), ev('tree-old.txt'))) &&
            (wd_new = tree_of(File.basename(c.new_ebuild), ev('tree-new.txt')))
        source_surface(wd_old, wd_new)
      elsif c.install
        Log.log 'surface diff unavailable (unpack blocked - pkg_setup needs build deps); relying on the emerge build gate'
      else
        raise Escalate.new(
          "surface diff unavailable (unpack blocked, likely pkg_setup needs build deps); re-run with --install",
          c.evidence.dir)
      end
      if c.diff_only
        # cli's cleanup restores the tree; signal a clean stop.
        raise DiffOnlyDone, c.evidence.dir
      end
    end

    class DiffOnlyDone < StandardError
      attr_reader :dir
      def initialize(dir) = (super('diff-only'); @dir = dir)
    end

    private

    def ev(name) = @c.evidence.path(name)

    def sudo_env = { 'SUDO' => @c.cfg.sudo }

    # prebuilt payload signals: SRC_URI archive ext, unpacker eclass, QA_PREBUILT,
    # or the -bin PN convention. Do NOT key off RESTRICT=bindist/strip (common on
    # from-source ebuilds).
    def payload?
      t = File.read(@c.new_ebuild, encoding: 'UTF-8').scrub
      # scan an 8-line window from EVERY SRC_URI line: the match must survive a SRC_URI
      # in the last 8 lines / a file <9 lines (each_cons(9) yields no window there) and
      # a later SRC_URI+= whose archive ext differs from the first.
      lines = t.lines
      src = lines.each_index.select { |i| lines[i] =~ /^[[:space:]]*SRC_URI/ }
                 .map { |i| lines[i, 9].join }.join
      src =~ /\.(deb|AppImage|exe|dmg)/ ||
        t.lines.any? { |l| l =~ /inherit.*unpacker/ } ||
        t.lines.any? { |l| l =~ /^[[:space:]]*QA_PREBUILT=/ } ||
        @c.pn.end_with?('-bin')
    end

    # ebuild clean unpack; list the workdir file tree. nil if unpack fails.
    # MUST run in pkgdir: the pipeline stays cd'd in PKGDIR from stage 4 through stage 6,
    # and `ebuild` is invoked by basename. (A --diff-only test caught this: without the
    # chdir the unpack fails and a clean source bump wrongly escalates.)
    def tree_of(eb, out)
      _, ok = Dir.chdir(@c.pkgdir) { @c.sh('ebuild', eb, 'clean', 'unpack', sudo: true, timeout: @c.cfg.op_timeout) }
      return nil unless ok
      pvr = File.basename(eb, '.ebuild').sub(/\A#{Regexp.escape(@c.pn)}-/, '')
      tmpd = `portageq envvar PORTAGE_TMPDIR 2>/dev/null`.strip
      tmpd = '/var/tmp' if tmpd.empty?
      wd = "#{tmpd}/portage/#{@c.cat}/#{@c.pn}-#{pvr}/work"
      system(sudo_env, 'bash', '-c', 'exec $SUDO find "$1" -type f -printf "%P\n" 2>/dev/null | sort > "$2"', 'bash', wd, out)
      wd
    end

    def surface_of(wd, out)
      system(sudo_env, 'bash', '-c', SURFACE_SH, 'bash', wd, out)
    end

    def comm(flag, a, b)
      `comm #{flag} #{a.shellescape} #{b.shellescape}`
    end

    # payload branch (396-431): removed path is dangerous unless it is a benign
    # version-embedded rename (old path with OLD_PV->NEWVER appears in added).
    def payload_diff
      c = @c
      if c.old_distfile_missing
        Log.log 'payload: OLD distfile unavailable -> tree diff skipped; the PR is flagged "no diff" for human review'
        return
      end
      tree_of(File.basename(c.old_ebuild), ev('tree-old.txt')) or (raise Abort, 'unpack old failed')
      tree_of(File.basename(c.new_ebuild), ev('tree-new.txt')) or (raise Abort, 'unpack new failed')
      File.write(ev('tree-removed.txt'), comm('-23', ev('tree-old.txt'), ev('tree-new.txt')))
      File.write(ev('tree-added.txt'),   comm('-13', ev('tree-old.txt'), ev('tree-new.txt')))
      removed = File.readlines(ev('tree-removed.txt')).map(&:chomp).reject(&:empty?)
      added   = File.readlines(ev('tree-added.txt')).map(&:chomp).reject(&:empty?)
      real_removed, real_added, churned = self.class.fold_benign(removed, added, c.old_pv, c.newver)
      # always write both real (structural-only) files + the churn count, so the PR body can tell
      # "compared, no structural change" from "not compared" and can note the asset churn.
      File.write(ev('tree-removed-real.txt'), real_removed.empty? ? '' : real_removed.join("\n") + "\n")
      File.write(ev('tree-added-real.txt'),   real_added.empty?   ? '' : real_added.join("\n") + "\n")
      File.write(ev('tree-churn-count.txt'), churned.to_s)
      if real_removed.any? && !c.accept_payload
        puts real_removed.first(20).join("\n")
        puts "== payload layout changed (#{real_removed.size} structural removals / #{real_added.size} additions; #{churned} asset-churn + version-renames ignored);"
        puts '== a removed path may be a real break (renamed .desktop) or benign (dropped icon size).'
        puts '== inspect tree-removed-real.txt, then re-run with --accept-payload if harmless.'
        raise Escalate.new('payload layout changed', c.evidence.dir)
      end
      if real_removed.any?
        puts real_removed.first(20).join("\n")
        Log.log "payload: #{real_removed.size} removed path(s) accepted as harmless (--accept-payload)"
      end
      Log.ok "payload tree: #{real_added.size} new / #{real_removed.size} removed structural (#{churned} asset-churn/version-renames ignored)"
    end

    # source branch (432-454): build-option surface delta.
    def source_surface(wd_old, wd_new)
      c = @c
      surface_of(wd_old, ev('surface-old.txt'))
      surface_of(wd_new, ev('surface-new.txt'))
      File.write(ev('surface-removed.txt'), comm('-23', ev('surface-old.txt'), ev('surface-new.txt')))
      File.write(ev('surface-added.txt'),   comm('-13', ev('surface-old.txt'), ev('surface-new.txt')))
      sdel = File.readlines(ev('surface-removed.txt')).reject { |l| l.strip.empty? }.size
      sadd = File.readlines(ev('surface-added.txt')).reject { |l| l.strip.empty? }.size
      if (sdel + sadd).positive? && !c.accept_surface
        puts '--- surface added ---';   print File.read(ev('surface-added.txt'))
        puts '--- surface removed ---'; print File.read(ev('surface-removed.txt'))
        puts "== build-option surface changed (+#{sadd}/-#{sdel}): may need USE/RDEPEND changes."
        puts '== judge the evidence, then re-run with --accept-surface if it is harmless.'
        raise Escalate.new('build-option surface changed', c.evidence.dir)
      end
      if c.accept_surface
        Log.log "surface delta accepted by judge (+#{sadd}/-#{sdel})"
      else
        Log.ok 'build-option surface unchanged'
      end
    end
  end
end
