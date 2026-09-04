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
    # stem, hash run, extension: the run sits before the final extension, or before a
    # sourcemap/licence companion of it. The stem is greedy so only the LAST token is the run.
    FINGERPRINT_NAME = /\A[0-9a-f]{48}-(?<chunk>[A-Za-z0-9_-]{7,})(?<ext>\.[A-Za-z0-9]+(?:\.(?:map|LICENSE\.txt))?)\z/
    HASH_NAME = /\A(?<stem>.+[-.])(?<run>[A-Za-z0-9_-]{7,})(?<ext>\.[A-Za-z0-9]+(?:\.(?:map|LICENSE\.txt))?)\z/
    # A script or style bundle: what rule (4) treats as a chunk, on top of an integer name.
    CHUNK_EXT = /\.(?:js|mjs|cjs|css)(?:\.map|\.LICENSE\.txt)?\z/

    # A base64url content hash, as vite and rollup spell it: an upper-case letter plus
    # something that is not upper-case, so BIS-CJUO and u_Su6bzX read as hashes while a word
    # like CHANGELOG or `modules` stays a name a maintainer may care about.
    def self.content_hash_run?(run)
      run.length >= 8 && run.match?(/[A-Z]/) && run.match?(/[a-z0-9_-]/)
    end

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
    def self.fold_benign(removed, added, old_pv, newver, new_tree: nil)
      renames = version_forms(old_pv).zip(version_forms(newver))
      real_removed = removed.reject { |p| renames.any? { |old, new| added.include?(p.gsub(old, new)) } }
      real_added   = added.reject   { |p| renames.any? { |old, new| removed.include?(p.gsub(new, old)) } }
      churned = 0

      # (2a) a deployment fingerprint in front of a stable chunk id: claude-desktop ships
      #      <48 hex>-CVu4teRk.js and redeploys it under a new digest with the same id. This
      #      runs before the hash fold below, which would otherwise drop the addition that
      #      identifies the pair. Fixed-width lowercase hex only, and 1:1 in one directory, so
      #      an ordinary hyphenated name cannot match and an unreplaced file stays structural.
      fingerprint_key = lambda do |p|
        match = File.basename(p).match(FINGERPRINT_NAME)
        next if match.nil?

        "#{File.dirname(p)}/#{VER_HOLE}-#{match[:chunk]}#{match[:ext]}"
      end
      real_removed, real_added, folded =
        fold_pairs(real_removed, real_added,
                   candidate: ->(p) { !fingerprint_key.call(p).nil? }, key: fingerprint_key)
      churned += folded

      # (2) a content-hash rename. A lowercase word is a name, not a hash: require a digit or
      #     mixed case, so a renamed `org.example.desktop` stays structural while
      #     `kernel.C5XtPPRo.js` folds. Only the run before the extension is blanked, so a
      #     stable bundle id in front of it stays in the key: kiro ships
      #     chunk-2GRJ4B5K-Dtk3djQK.js and rebuilds it as chunk-2GRJ4B5K-DrXvAXa3.js, and
      #     blanking both tokens collapsed every chunk in the directory onto one key, which
      #     never pairs. Hash-bearing additions fold on their own -- an addition cannot
      #     escalate, and folding it keeps the churn count meaningful.
      hash_key = lambda do |p|
        match = File.basename(p).match(HASH_NAME)
        next if match.nil?

        run = match[:run]
        next unless run.match?(/\d/) || (run.match?(/[a-z]/) && run.match?(/[A-Z]/))

        "#{File.dirname(p)}/#{match[:stem]}#{VER_HOLE}#{match[:ext]}"
      end
      real_removed, real_added, folded =
        fold_pairs(real_removed, real_added, drop_added: true,
                   candidate: ->(p) { !hash_key.call(p).nil? }, key: hash_key)
      churned += folded

      # (3) an independently-versioned bundled artifact: jetbrains-toolbox moves
      #     bin/lib/agent-client-0.8.6635.jar to 0.8.6806 while the package goes
      #     3.6.2.85969 -> 3.6.3.86383, so (1) cannot pair it by the package version.
      real_removed, real_added, folded =
        fold_pairs(real_removed, real_added, candidate: ->(_p) { true },
                   key: ->(p) { "#{File.dirname(p)}/#{File.basename(p).gsub(/\d+(?:\.\d+)+/, VER_HOLE)}" })
      churned += folded

      # (4) a renumbered bundler chunk. Webpack numbers chunks per build, so a rebuilt
      #     bundle renames the whole directory at once and the sets never pair one to one:
      #     cursor's cursor-agent-host/dist drops 20 chunks and adds 200. Fold a directory's
      #     chunks while that directory came back at least as large, so a dist/ that emptied
      #     out or shrank is still a removal. The basename must be an integer and the extension
      #     a script or style one, so a dropped icon16.png next to an added icon32.png stays
      #     structural. A content-hashed chunk counts too: claude-desktop swaps two of 2757
      #     assets for two under different ids, and no per-name key can pair those - the name
      #     is the content. The directory's own count is the check that nothing was dropped.
      chunk = lambda do |p|
        base = File.basename(p)
        next false unless base.match?(CHUNK_EXT)
        next true if base.match?(/\A\d+#{CHUNK_EXT.source}/o)

        run = base.match(FINGERPRINT_NAME)&.[](:chunk) || base.match(HASH_NAME)&.[](:run)
        !run.nil? && content_hash_run?(run)
      end
      chunks_per_dir = lambda do |paths|
        paths.select(&chunk).group_by { |p| File.dirname(p) }.transform_values(&:size)
      end
      # counted from the diff as it arrived: rule (2) discards hash-bearing additions on sight,
      # and counting what is left would make every rebuilt directory look like it shrank
      gained = chunks_per_dir.call(added)
      lost = chunks_per_dir.call(removed)
      # a rebuild renumbers, it does not net-delete: a directory that came back smaller lost
      # something, and that is what a maintainer has to see
      # a rebuild renames what was there: a directory that only gained chunks did not rebuild,
      # and one that came back smaller lost something a maintainer has to see
      rebuilt_dirs = gained.select { |dir, n| lost.fetch(dir, 0).positive? && n >= lost[dir] }.keys
      renumbered = ->(p) { chunk.call(p) && rebuilt_dirs.include?(File.dirname(p)) }
      kept_removed = real_removed.reject(&renumbered)
      kept_added = real_added.reject(&renumbered)
      churned += (real_removed.size - kept_removed.size) + (real_added.size - kept_added.size)
      real_removed, real_added = kept_removed, kept_added

      # (5) a bundle output directory. claude-desktop's ion-dist/assets/v1 holds 2760 files and
      #     every one of them is named after its content, so a rebuild churns an arbitrary
      #     subset and no per-name key pairs the ones whose id moved. When nine in ten names in
      #     a directory are content hashes, the directory is bundler output: fold its churn
      #     while it did not come back smaller. The file itself must be hash-named too, so an
      #     index.html dropped from such a directory is still a removal a maintainer sees.
      real_removed, real_added, folded =
        fold_bundle_dirs(real_removed, real_added, removed, added, new_tree)
      churned += folded

      [real_removed, real_added, churned]
    end

    def self.hash_named?(path)
      base = File.basename(path)
      base.match?(FINGERPRINT_NAME) || base.match?(HASH_NAME)
    end

    def self.fold_bundle_dirs(real_removed, real_added, removed, added, new_tree)
      return [real_removed, real_added, 0] if new_tree.nil? || new_tree.empty?

      bundle_dirs = new_tree.group_by { |p| File.dirname(p) }
                            .select { |_dir, files| files.size >= 8 && files.count { |f| hash_named?(f) } * 10 >= files.size * 9 }
                            .keys
      per_dir = lambda { |paths| paths.group_by { |p| File.dirname(p) }.transform_values(&:size) }
      gained, lost = per_dir.call(added), per_dir.call(removed)
      rebuilt = bundle_dirs.select { |dir| gained.fetch(dir, 0) >= lost.fetch(dir, 0) }
      churn = ->(p) { rebuilt.include?(File.dirname(p)) && hash_named?(p) }
      kept_removed, kept_added = real_removed.reject(&churn), real_added.reject(&churn)
      [kept_removed, kept_added,
       (real_removed.size - kept_removed.size) + (real_added.size - kept_added.size)]
    end

    # The shared safety rule behind (2), (3) and (4): a removal folds only when exactly one
    # addition carries the same key, so an unreplaced or ambiguous removal always survives.
    # `drop_added` additionally discards every candidate addition, which only rule (2) wants.
    # Returns [removed, added, folded_count].
    # How an ebuild can spell its version in a payload path: as PV, as the MY_PV="${PV/_p/-}"
    # family, and as the dotted core without a suffix - ungoogled-chromium-bin unpacks into
    # ungoogled-chromium-152.0.7977.64-1-x86_64_linux/ for PV 152.0.7977.64_p1. The core is
    # only used when it carries a dot: a bare number would substitute all over the path.
    def self.version_forms(version)
      core = version[/\A\d+(?:\.\d+)+/]
      [version, version.sub(/_p(\d*)/, '-\1'), core].compact.uniq
    end

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
      new_tree = File.readlines(ev('tree-new.txt')).map(&:chomp).reject(&:empty?)
      real_removed, real_added, churned =
        self.class.fold_benign(removed, added, c.old_pv, c.newver, new_tree: new_tree)
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
