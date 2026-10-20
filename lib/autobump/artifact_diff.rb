# frozen_string_literal: true
require 'open3'
require 'shellwords'
module Autobump
  # Stage 5: artifact diff. Prebuilt payload -> unpack both and diff the file tree
  # (a removed path is dangerous unless it is a version-embedded rename, or nothing in either
  # tree, the ebuild or files/ can still need it and BuildTest's smoke test runs). Source ->
  # diff the build-option surface (cmake/meson/autotools/cargo); a changed surface
  # may need a USE flag or dependency.
  #
  # The find/grep/sed/awk pipelines run as a single bash heredoc, so the surface extraction
  # is one block instead of a chain of Ruby shell-outs.
  class ArtifactDiff
    SURFACE_SH = <<~'SH'
      # S, not the first directory: WORKDIR also holds unpacked bundles such as cargo_home or dist
      top=$($SUDO sed -n 's/^declare -[-x]* S="\(.*\)"$/\1/p' "$3" 2>/dev/null)
      [ -n "$top" ] && $SUDO test -d "$top" || top=$($SUDO find "$1" -maxdepth 1 -mindepth 1 -type d | head -1)
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
    # Rule (6): inside an app tree every file is an asset except native objects, launchers and
    # extensionless files, which may be executables; licence files are assets despite no extension.
    APP_TREE = %r{(?:\A|/)(?:resources/app|node_modules)/}
    APP_NATIVE = /\.(?:so(?:\.[0-9]+)*|node|desktop|sh)\z/
    LICENCE_NAME = /\A(?:LICEN[CS]E|COPYING|NOTICE|README|CHANGELOG|AUTHORS)(?:[.-].*)?\z/i

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
      # the payload's top directory usually carries the package version, so a directory read
      # literally never matches across a bump: rebased-bin ships
      # rebased-bin-1.1.14/lib/build-marker-IC-262.9437.SNAPSHOT and moves both numbers at once.
      # Only the package's own version is blanked, so a lib/python3.12 stays what it is.
      forms = (version_forms(old_pv) + version_forms(newver)).sort_by { |f| -f.length }
      dir_of = ->(p) { forms.reduce(File.dirname(p)) { |acc, form| acc.gsub(form, VER_HOLE) } }
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

        "#{dir_of.call(p)}/#{VER_HOLE}-#{match[:chunk]}#{match[:ext]}"
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

        "#{dir_of.call(p)}/#{match[:stem]}#{VER_HOLE}#{match[:ext]}"
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
                   key: ->(p) { "#{dir_of.call(p)}/#{File.basename(p).gsub(/\d+(?:\.\d+)+/, VER_HOLE)}" })
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
        paths.select(&chunk).group_by(&dir_of).transform_values(&:size)
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
      renumbered = ->(p) { chunk.call(p) && rebuilt_dirs.include?(dir_of.call(p)) }
      kept_removed = real_removed.reject(&renumbered)
      kept_added = real_added.reject(&renumbered)
      churned += (real_removed.size - kept_removed.size) + (real_added.size - kept_added.size)
      real_removed, real_added = kept_removed, kept_added

      # (5) a bundle output directory. claude-desktop's ion-dist/assets/v1 holds 2760 files
      #     named after their content and cursor's cursor-agent-host/dist holds 116 numbered
      #     chunks; a rebuild churns an arbitrary subset of either, and no per-name key pairs
      #     the ones that moved. When nine names in ten are bundler-generated the directory is
      #     bundler output: fold its churn while what survives there outnumbers what it lost.
      #     The file itself must be bundler-named too, so an index.html dropped from such a
      #     directory is still a removal a maintainer sees.
      real_removed, real_added, folded =
        fold_bundle_dirs(real_removed, real_added, removed, new_tree, dir_of)
      churned += folded

      # (6) application assets: moved bundles and re-hoisted node_modules are churn; ELF objects,
      #     launchers and .desktop files outside these trees still count.
      app_asset = lambda do |p|
        base = File.basename(p)
        p.match?(APP_TREE) && !base.match?(APP_NATIVE) && (base.include?('.') || base.match?(LICENCE_NAME))
      end
      kept_removed, kept_added = real_removed.reject(&app_asset), real_added.reject(&app_asset)
      churned += (real_removed.size - kept_removed.size) + (real_added.size - kept_added.size)
      real_removed, real_added = kept_removed, kept_added

      # (7) a native module rebuilt for a new runtime ABI: openchamber's node-pty moved
      #     prebuilds/linux-x64-148/pty.node to linux-x64-149/pty.node with its Electron. Only
      #     whole numbers between `-`, `_` or `.` in the parent directory's name are blanked, so
      #     the `64` of `x64` stays and an x86 module is no rename of an x64 one; the pair must be 1:1.
      abi_key = lambda do |p|
        parent = File.dirname(p)
        "#{dir_of.call(parent)}/#{File.basename(parent).gsub(/(?<![^-_.])\d+(?![^-_.])/, VER_HOLE)}/#{File.basename(p)}"
      end
      real_removed, real_added, folded =
        fold_pairs(real_removed, real_added, candidate: ->(p) { p.end_with?('.node') }, key: abi_key)
      churned += folded

      [real_removed, real_added, churned]
    end

    def self.hash_named?(path)
      base = File.basename(path)
      base.match?(FINGERPRINT_NAME) || base.match?(HASH_NAME)
    end

    def self.bundler_named?(path)
      File.basename(path).match?(/\A\d+#{CHUNK_EXT.source}/o) || hash_named?(path)
    end

    def self.fold_bundle_dirs(real_removed, real_added, removed, new_tree, dir_of)
      return [real_removed, real_added, 0] if new_tree.nil? || new_tree.empty?

      survivors = new_tree.group_by(&dir_of)
      bundle_dirs = survivors.select do |_dir, files|
        files.size >= 8 && files.count { |f| bundler_named?(f) } * 10 >= files.size * 9
      end.keys
      lost = removed.group_by(&dir_of).transform_values(&:size)
      # what survives is the check: cursor's dist coming back with 116 chunks after dropping 26
      # is a rebuild repartitioning its modules, and one coming back with 3 is not
      rebuilt = bundle_dirs.select { |dir| survivors[dir].size >= lost.fetch(dir, 0) }
      churn = ->(p) { rebuilt.include?(dir_of.call(p)) && bundler_named?(p) }
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

    # A structural removal waits for the build only when nothing could still need it. A file
    # that was executable, a shared object or native module, a desktop entry or unit file needs
    # a human, except the libraries a newer Electron stops shipping beside its binary
    # (openchamber, kiro): those pass when no ELF object in the new tree still NEEDs them.
    ANGLE_FILES = %w[libEGL.so libGLESv2.so libvk_swiftshader.so vk_swiftshader_icd.json].freeze
    ELECTRON_MARKERS = %w[resources.pak icudtl.dat v8_context_snapshot.bin snapshot_blob.bin].freeze
    ELECTRON_HELPERS = %w[chrome-sandbox chrome_crashpad_handler].freeze
    NATIVE_OBJECT = /\.(?:so(?:\.\d+)*|node)\z/
    CONSUMER_FILE = /\.(?:desktop|service|socket|timer)\z/
    ICON_FILE = /\.(?:png|svg|xpm|ico)\z/
    TEXT_FILE_CAP = 256 * 1024
    TEXT_TOTAL_CAP = 64 * 1024 * 1024
    # the new tree's .desktop entries, scripts and small configs that mention a removed name;
    # TRUNCATED on stderr when one of those configs reaches the per-file cap or they add up to
    # more than the total cap. Executables at or over the per-file cap are skipped: they are
    # binaries (Electron's main binary is ~170 MB), and a script is not that large. A grep that
    # fails rather than finds nothing exits 255, so xargs stops with 124; with pipefail that,
    # an awk failure, or a child killed by a signal (xargs 125) all fail the read.
    TEXT_HITS_SH = <<~'SH'
      set -o pipefail
      list=$($SUDO find "$1" -type f \( \( -name '*.desktop' -o -name '*.sh' -o -name '*.json' \
          -o -name '*.ini' -o -name '*.conf' -o -name '*.yml' -o -name '*.yaml' -o -name '*.service' \) \
          -printf 't %s %p\n' -o -perm /111 -size -"$3"c -printf 'x %s %p\n' \)) || exit 2
      printf '%s\n' "$list" \
        | awk -v fcap="$3" -v cap="$4" 'stop || !NF { next }
            { total += $2 }
            ($1 == "t" && $2 >= fcap) || total > cap { print "TRUNCATED" > "/dev/stderr"; stop = 1; next }
            { sub(/^[tx] [0-9]+ /, ""); printf "%s%c", $0, 0 }' \
        | xargs -0 -r sh -c '"$@"; [ $? -le 1 ] || exit 255' sh $SUDO grep -IHnFZ -f "$2" --
    SH

    # Why each removal still needs a human; empty when the build may decide them all. Pure, so
    # test/payload_removals.rb can pin every condition. Returns [[path, reason], ...].
    #   old_exec       paths that were executable in the old tree
    #   refs           {name => text} of the new ebuild and every file under files/
    #   text_hits      [[path, line]] from the new tree's .desktop entries, scripts and configs
    #   text_complete  false when one of those configs reached TEXT_FILE_CAP or all exceeded
    #                  TEXT_TOTAL_CAP, so not all were read
    #   needed         {path => [NEEDED entries]} of the new tree's ELF objects; nil if unknown
    def self.removal_blockers(removed, new_tree:, old_exec:, refs:, text_hits:, text_complete:, needed:)
      blockers = []
      unless text_complete
        blockers << ['(all)', "the new tree's text files were not all read (one reaches #{TEXT_FILE_CAP} bytes " \
                              "or all exceed #{TEXT_TOTAL_CAP})"]
      end
      removed.each do |p|
        base = File.basename(p)
        # Electron's libraries are often mode 755, so their own rule comes before the mode
        why = if ANGLE_FILES.include?(base) then angle_blocker(p, new_tree, needed)
              elsif old_exec.include?(p) then 'executable in the old tree'
              elsif base.match?(CONSUMER_FILE) then 'a desktop entry or unit file'
              elsif base.match?(NATIVE_OBJECT) then 'a shared object or native module'
              end
        # a .desktop entry names its icon without the extension
        icon = "Icon=#{base.sub(ICON_FILE, '')}" if base.match?(ICON_FILE)
        why ||= mention(refs, base, icon) || mention(text_hits, base, icon)
        blockers << [p, why] if why
      end
      blockers
    end

    def self.mention(sources, base, icon)
      sources.each do |name, text|
        line = text.each_line.find { |l| l.include?(base) || (icon && l.strip == icon) }
        return "#{name} names it: #{line.strip}" if line
      end
      nil
    end

    def self.angle_blocker(path, new_tree, needed)
      dir = File.dirname(path)
      return 'not beside an Electron binary in the new tree' unless ELECTRON_MARKERS.any? { |m| new_tree.include?("#{dir}/#{m}") }
      return 'NEEDED of the new tree unknown (scanelf failed)' if needed.nil?

      main = needed.keys.select do |f|
        File.dirname(f) == dir && !File.basename(f).include?('.') && !ELECTRON_HELPERS.include?(File.basename(f))
      end
      return 'no Electron binary beside it in the new tree' if main.empty?

      # a NEEDED entry may be spelled as a path (/opt/app/libEGL.so)
      user = needed.find { |_f, libs| libs.any? { |l| File.basename(l) == File.basename(path) } }
      "still NEEDED by #{user[0]}" if user
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
      system(sudo_env, 'bash', '-c', SURFACE_SH, 'bash', wd, out, File.join(File.dirname(wd), 'temp/environment'))
    end

    def comm(flag, a, b)
      `comm #{flag} #{a.shellescape} #{b.shellescape}`
    end

    # payload branch (396-431): removed path is dangerous unless it is a benign
    # version-embedded rename (old path with OLD_PV->NEWVER appears in added). A removal that
    # removal_blockers cannot tie to anything is left to BuildTest instead of escalating here.
    def payload_diff
      c = @c
      if c.old_distfile_missing
        Log.log 'payload: OLD distfile unavailable -> tree diff skipped; the PR is flagged "no diff" for human review'
        return
      end
      wd_old = tree_of(File.basename(c.old_ebuild), ev('tree-old.txt')) or (raise Abort, 'unpack old failed')
      wd_new = tree_of(File.basename(c.new_ebuild), ev('tree-new.txt')) or (raise Abort, 'unpack new failed')
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
        blockers = removal_blockers_of(real_removed, new_tree, wd_old, wd_new)
        blockers << ['(all)', 'only an install and smoke test can clear them, and this run does not build (--install)'] \
          unless c.install && !c.diff_only
        if blockers.any?
          File.write(ev('tree-removed-blocked.txt'), blockers.map { |p, why| "#{p}\t#{why}\n" }.join)
          puts real_removed.first(20).join("\n")
          puts "== payload layout changed (#{real_removed.size} structural removals / #{real_added.size} additions; #{churned} asset-churn + version-renames ignored);"
          puts blockers.first(20).map { |p, why| "== #{p}: #{why}" }.join("\n")
          puts '== inspect tree-removed-blocked.txt, then re-run with --accept-payload if harmless.'
          path, why = blockers.first
          raise Escalate.new("payload layout changed (#{path}: #{why[0, 160]})", c.evidence.dir)
        end
        # BuildTest accepts them after a clean install and a smoke test that ran the app
        c.payload_pending = real_removed
        Log.log "payload: #{real_removed.size} removed path(s) named nowhere; the install and smoke test decide"
      elsif real_removed.any?
        puts real_removed.first(20).join("\n")
        Log.log "payload: #{real_removed.size} removed path(s) accepted as harmless (--accept-payload)"
      end
      Log.ok "payload tree: #{real_added.size} new / #{real_removed.size} removed structural (#{churned} asset-churn/version-renames ignored)"
    end

    # Gather what removal_blockers reads from the two unpacked trees and the package directory.
    def removal_blockers_of(removed, new_tree, wd_old, wd_new)
      c = @c
      modes, modes_ok = Open3.capture2(sudo_env, 'bash', '-c', '$SUDO find "$1" -type f -perm /111 -printf "%P\n"',
                                       'bash', wd_old)
      files = Dir.glob('files/**/*', base: c.pkgdir).select { |f| File.file?(File.join(c.pkgdir, f)) }
      refs = ([File.basename(c.new_ebuild)] + files).to_h do |f|
        [f, File.read(File.join(c.pkgdir, f), encoding: 'UTF-8').scrub]
      end
      patterns = removed.map { |p| File.basename(p) } +
                 removed.grep(ICON_FILE).map { |p| "Icon=#{File.basename(p).sub(ICON_FILE, '')}" }
      File.write(ev('tree-removed-patterns.txt'), patterns.uniq.join("\n") + "\n")
      hits, errs, read = Open3.capture3(sudo_env, 'bash', '-c', TEXT_HITS_SH, 'bash', wd_new,
                                   ev('tree-removed-patterns.txt'), TEXT_FILE_CAP.to_s, TEXT_TOTAL_CAP.to_s)
      # grep -Z ends the file name with NUL, so a `:` in the path cannot shift the fields
      text_hits = hits.scrub.lines.filter_map do |l|
        file, rest = l.chomp.split("\0", 2)
        _lineno, line = rest.to_s.split(':', 2)
        [file.delete_prefix("#{wd_new}/"), line] if line
      end
      elf, ok = Open3.capture2(sudo_env, 'bash', '-c', '$SUDO scanelf -qRyBF "%F;%n" "$1" 2>/dev/null',
                               'bash', wd_new)
      needed = if ok.success?
                 elf.scrub.lines.to_h do |l|
                   file, libs = l.chomp.split(';', 2)
                   [file.delete_prefix("#{wd_new}/"), libs.to_s.split(',')]
                 end
               end
      blockers = self.class.removal_blockers(removed, new_tree: new_tree, old_exec: modes.lines.map(&:chomp),
                                             refs: refs, text_hits: text_hits,
                                             text_complete: !errs.include?('TRUNCATED'), needed: needed)
      blockers.unshift(['(all)', 'the old tree\'s file modes could not be read']) unless modes_ok.success?
      blockers.unshift(['(all)', "the new tree's text files could not be read: #{errs.strip[0, 120]}"]) unless read.success?
      blockers
    end

    CARGO_FEATURE = /\Acargo-feature:([a-z0-9_-]+)/
    # Cargo feature names contain `-`, so unlike grep -w a `-` also continues a word: `cli` is
    # not named by the `${PN/-cli/}` of cc-switch-cli, nor `gui` by `guide`.
    FEATURE_CHAR = '[A-Za-z0-9_-]'

    def self.names_word?(text, word)
      text.match?(/(?<!#{FEATURE_CHAR})#{Regexp.escape(word)}(?!#{FEATURE_CHAR})/)
    end

    # The surface lines for Cargo features the ebuild never names. Cargo builds `default` plus
    # the features the ebuild passes (--features, myfeatures, usually behind a USE flag), so
    # adding or removing any other one leaves the ebuild as it is. `default` itself always
    # counts, because adding or dropping it changes what Cargo builds, and nothing is ignored
    # under --all-features, which builds every feature.
    def self.ignored_cargo_features(lines, ebuild_text)
      return [] if ebuild_text.include?('all-features')

      lines.select do |l|
        name = l[CARGO_FEATURE, 1] or next false
        name != 'default' && !names_word?(ebuild_text, name)
      end
    end

    # source branch (432-454): build-option surface delta.
    def source_surface(wd_old, wd_new)
      c = @c
      surface_of(wd_old, ev('surface-old.txt'))
      surface_of(wd_new, ev('surface-new.txt'))
      File.write(ev('surface-removed.txt'), comm('-23', ev('surface-old.txt'), ev('surface-new.txt')))
      File.write(ev('surface-added.txt'),   comm('-13', ev('surface-old.txt'), ev('surface-new.txt')))
      removed = File.readlines(ev('surface-removed.txt')).reject { |l| l.strip.empty? }
      added = File.readlines(ev('surface-added.txt')).reject { |l| l.strip.empty? }
      # cc-switch-cli 5.11.1 and gitoxide 0.60.0 escalated on features neither ebuild selects
      text = File.read(c.new_ebuild, encoding: 'UTF-8').scrub
      ign_del = ArtifactDiff.ignored_cargo_features(removed, text)
      ign_add = ArtifactDiff.ignored_cargo_features(added, text)
      ignored = ign_add.map { |l| "+#{l}" } + ign_del.map { |l| "-#{l}" }
      unless ignored.empty?
        File.write(ev('surface-ignored.txt'), ignored.join)
        Log.log "surface: #{ignored.size} Cargo feature change(s) the ebuild does not name ignored " \
                "(#{ev('surface-ignored.txt')})"
      end
      sdel = (removed - ign_del).size
      sadd = (added - ign_add).size
      if (sdel + sadd).positive? && !c.accept_surface
        puts '--- surface added ---';   print File.read(ev('surface-added.txt'))
        puts '--- surface removed ---'; print File.read(ev('surface-removed.txt'))
        puts '--- ignored: Cargo features the ebuild does not name ---', ignored.join unless ignored.empty?
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
