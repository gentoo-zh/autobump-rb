# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Stage 6: build test.
  #  - Prebuilt payload: `ebuild install` (no deps) + QA gate (ignore the
  #    unresolved-soname notice that resolves once RDEPEND is installed).
  #  - Source: only build-tested with --install (surface diff otherwise).
  #  - --install: copy into the live overlay if separate, accept ~amd64 overlay-wide,
  #    emerge with CI's exact elog config, gate on the elog byte-for-byte like CI,
  #    smoke the version, advisory GUI launch probe, advisory qa-vdb linked-libs check.
  # Defers (Abort, exit 2) on a timeout or a local dependency-resolution gap; escalates
  # (exit 3) on a real build/QA failure.
  class BuildTest
    # dependencies whose from-source build runs for hours and blows any CI op-timeout. CI aligns
    # their USE to the binhost (package.use/ci-binhost) so they normally arrive as binpkgs; this
    # pre-check fires only when the plan would STILL build one from source (no matching binpkg),
    # deferring early instead of timing out. Not exhaustive -- add packages as they surface.
    # net-libs/nodejs is deliberately NOT here: its from-source build is ~1h (moderate, not the
    # multi-hour builds above), so CI is given op-timeout headroom to build it rather than defer
    # the pnpm/npm family. Keep it off this list in step with autobump.yml's raised AUTOBUMP_OP_TIMEOUT.
    HEAVY = %w[
      dev-qt/qtwebengine dev-qt/qtwebkit net-libs/webkit-gtk
      www-client/chromium www-client/firefox mail-client/thunderbird
      dev-lang/rust dev-lang/spidermonkey dev-lang/ghc dev-lang/mono
      sys-devel/gcc sys-devel/clang sys-devel/llvm llvm-core/clang llvm-core/llvm
      app-office/libreoffice media-gfx/blender dev-db/mongodb dev-db/mariadb dev-db/mysql
    ].freeze

    def initialize(ctx) = (@c = ctx)

    def run
      c = @c
      c.smoke = 'not run (use --install)'
      if c.payload
        prebuilt_gate
      elsif !c.install
        Log.log 'source package: not build-tested without --install (surface-diff only); --pr implies --install'
      end
      install_and_smoke if c.install
    end

    private

    def ev(n) = @c.evidence.path(n)
    def neweb = File.basename(@c.new_ebuild)
    # array-form command with an optional leading sudo (dropped when empty=root), so
    # interpolated paths never go through a shell. Matches bash's "$SUDO cmd \"$path\"".
    def sudocmd(*a) = [@c.cfg.sudo, *a].reject { |x| x.nil? || x.empty? }

    # HEAVY packages the emerge plan would build FROM SOURCE (not fetch as a binpkg). The
    # target itself building from source is expected -- only a heavy dependency doing so is
    # the timeout risk. Best-effort: if pretend fails, returns [] and the real emerge runs.
    def heavy_from_source
      c = @c
      # same getbinpkg the real emerge uses (+ the CI package.use that aligns heavy-dep USE to the
      # binhost), so the plan predicts it: a heavy dep is [binary] when a USE-matching binpkg
      # exists, else [ebuild] -- and only then do we defer.
      plan = `#{c.cfg.sudo} emerge --pretend --getbinpkg =#{c.pkg}-#{c.newver} 2>/dev/null`
      self.class.heavy_in_plan(plan, c.pn, c.newver)
    end

    # pure parse of an `emerge --pretend` plan (extracted so it is testable without portage):
    # '[ebuild' = built from source, '[binary' = fetched binpkg. Return the HEAVY packages the
    # plan would build from source, excluding the bump target itself.
    def self.heavy_in_plan(plan, pn, newver)
      plan.lines.select { |l| l.include?('[ebuild') }
          .reject  { |l| l.include?("#{pn}-#{newver}") }
          .flat_map { |l| HEAVY.select { |h| l.include?(h) } }
          .uniq
    end

    def prebuilt_gate
      c = @c
      Dir.chdir(c.pkgdir) do
        out, ok, code = c.sh('ebuild', neweb, 'clean', 'install', sudo: true, timeout: c.cfg.op_timeout)
        c.evidence.write('build.log', out)
        unless ok
          puts out.lines.last(20).join
          # 124 = the op-timeout SIGTERM on a heavy prebuilt unpack (claude-desktop /
          # adspower-global .deb/AppImage), not a defect -> defer + retry, mirroring the
          # emerge path (emerge_failed), instead of a permanent escalate to a human.
          raise Abort, "ebuild install timed out (>#{c.cfg.op_timeout}s): heavy unpack, not a defect. Deferring." if code == 124
          raise Escalate.new('build failed', c.evidence.dir)
        end
        # ignore unresolved-soname (resolves once emerge installs RDEPEND); fail on any other QA
        qa = out.lines.select { |l| l.include?('QA Notice') }.reject { |l| l.include?('Unresolved soname') }
        if qa.any?
          i = out.lines.index { |l| l.include?('QA Notice') }
          puts out.lines[i, 20].join if i
          raise Escalate.new('QA notice during install (would fail CI elog gate)', c.evidence.dir)
        end
      end
      Log.ok 'ebuild install clean (soname resolution deferred to the emerge)'
    end

    def install_and_smoke
      c = @c; cfg = c.cfg; nul = File::NULL
      Dir.chdir(c.pkgdir) do
        if cfg.separate_overlay
          dst = "#{cfg.live_overlay}/#{c.pkg}"
          system(*sudocmd('mkdir', '-p', dst))
          files = Dir.glob('*.ebuild') + %w[Manifest metadata.xml].select { |f| File.exist?(f) }
          system(*sudocmd('cp', *files, "#{dst}/"), err: nul) unless files.empty?
          lic = File.read(neweb)[/^LICENSE="([^"]+)"/, 1]
          if lic && File.exist?("#{cfg.repo}/licenses/#{lic}")
            system(*sudocmd('cp', "#{cfg.repo}/licenses/#{lic}", "#{cfg.live_overlay}/licenses/#{lic}"))
          end
        end
      end
      # accept ~amd64 overlay-wide (build deps of overlay pkgs are often overlay pkgs)
      system(*sudocmd('mkdir', '-p', '/etc/portage/package.accept_keywords'), err: nul)
      kwfile = "/etc/portage/package.accept_keywords/autobump-#{c.pn}"
      # the overlay-wide accept must name THIS overlay's repo, not a hardcoded one
      repo_name = (File.read("#{cfg.repo}/profiles/repo_name").strip rescue 'gentoo-zh')
      IO.popen([*sudocmd('tee', kwfile), { out: nul }], 'w') do |io|
        io.puts "#{c.pkg} ~amd64"; io.puts "*/*::#{repo_name} ~amd64"
      end
      # pretend first: if a heavy dependency would build from source (no matching binpkg on
      # the binhost), the real emerge would blow the op-timeout. Defer now, culprit named,
      # instead of burning the whole timeout on a build CI cannot finish.
      heavy = heavy_from_source
      raise Abort, "would build #{heavy.join(', ')} from source (no matching binpkg); this exceeds the CI op-timeout. Not a mechanical bump for CI -- needs a matching binpkg or the build box." unless heavy.empty?
      # emerge with CI's exact elog config so we gate the same way CI does.
      plog = ev('plog')
      # LC_ALL=C so emerge_failed's English mask/blocker regex matches on any locale.
      cmd = ['timeout', cfg.op_timeout.to_s, cfg.sudo, 'env', 'LC_ALL=C',
             'PORTAGE_ELOG_CLASSES=qa warn error', 'PORTAGE_ELOG_SYSTEM=save',
             "PORTAGE_LOGDIR=#{plog}", 'emerge', '--oneshot', '--quiet', "=#{c.pkg}-#{c.newver}"].reject(&:empty?)
      out = IO.popen(cmd, err: [:child, :out], &:read).scrub
      erc = $?.exitstatus || (128 + ($?.termsig || 0)) # a signal-killed emerge is not nil
      c.evidence.write('emerge.log', out)
      return emerge_failed(out, erc) unless erc.zero?

      # THE elog gate: a saved qa/warn/error elog from the BUMPED package fails the merge
      # (the go.mod-QA notice goes only to elog). Scope it to the package's own elog files
      # ("<cat>:<pn>-<ver>:<ts>.log") -- a dependency the emerge pulled in writes its own
      # elog (e.g. net-libs/nodejs' "source /etc/profile if you plan to use nodejs" postinst
      # notice), and gating on that would wrongly fail every bump that depends on it.
      # `-name` still catches recursive FEATURES=split-elog layouts. Anchor the VERSION too
      # ("<cat>:<pn>-<newver>*"): otherwise a sibling sharing the pn prefix in the same
      # category (dev-python/conda vs conda-libmamba-solver) is wrongly attributed to this bump.
      # match BOTH portage layouts so a split-elog host doesn't silently pass a real elog:
      #   default flat  -> elog/<cat>:<pn>-<newver>:<ts>.log   (basename carries cat:)
      #   split-elog    -> elog/<cat>/<pn>-<newver>:<ts>.log   (cat is a dir, basename has no cat:)
      flat = "#{c.cat}:#{c.pn}-#{c.newver}*"
      elog_files = `#{cfg.sudo} find #{plog.shellescape}/elog -type f \\( -name #{flat.shellescape} -o -path "*/#{c.cat}/#{c.pn}-#{c.newver}:*" \\) 2>/dev/null`.lines.map(&:chomp).reject(&:empty?)
      if elog_files.any?
        dump = elog_files.map { |f| `#{cfg.sudo} cat #{f.shellescape} 2>/dev/null` }.join
        puts dump.lines.first(25).join
        raise Escalate.new('emerge produced a qa/warn/error elog (fails the CI elog gate)', c.evidence.dir)
      end
      smoke_version
      gui_probe if c.gui && !`command -v Xvfb 2>/dev/null`.strip.empty?
      qa_vdb
    ensure
      system(*sudocmd('rm', '-f', kwfile), err: nul) if defined?(kwfile) && kwfile
    end

    def smoke_version
      c = @c
      c.smoke = 'installed; no version output matched NEWVER (verify manually)'
      bins(c.pkg).each do |bin|
        %w[--version version -V].each do |vf|
          out = `timeout 20 #{bin.shellescape} #{vf} 2>&1 | head -3`
          next unless out.include?(c.newver)
          line = out.lines.find { |l| l.include?(c.newver) }.to_s.strip
          c.smoke = "#{vf} ok: #{File.basename(bin)}: #{line}"
          Log.ok "emerge + smoke: #{c.smoke}"
          return
        end
      end
      Log.ok "emerge + smoke: #{c.smoke}"
    end

    def bins(pkg)
      `qlist #{pkg.shellescape} 2>/dev/null`.lines.map(&:chomp).select { |l| l =~ %r{/s?bin/[^/]+$} }
    end

    # ADVISORY headless GUI launch probe (never escalates): a GUI app can install
    # clean yet crash on start, so a launch under Xvfb catches a broken bump early.
    def gui_probe
      c = @c
      # own PID (not pkill Xvfb) so teardown never kills an unrelated host Xvfb
      xvfb = spawn('Xvfb', ':99', '-screen', '0', '1280x1024x24',
                   out: File::NULL, err: File::NULL)
      sleep 1
      res = 'started headless, no crash'
      bins(c.pkg).each do |bin|
        perr = `DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 timeout 15 #{bin.shellescape} </dev/null 2>&1 >/dev/null`.scrub; prc = $?.exitstatus
        if perr.include?('no-sandbox')
          perr = `DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 timeout 15 #{bin.shellescape} --no-sandbox --disable-gpu </dev/null 2>&1 >/dev/null`.scrub; prc = $?.exitstatus
        end
        if perr =~ /error while loading shared librar|symbol lookup error|undefined symbol|GLIBC_[0-9.]+.? not found/i
          res = "#{File.basename(bin)} MISSING A LIBRARY at runtime - likely broken"; break
        end
        case prc
        when 132, 134, 135, 136, 139 then res = "#{File.basename(bin)} crashed on start (signal #{prc - 128}) - verify (could be headless GL)"; break
        when 124 then res = 'ran 15s headless without crashing'; break
        end
      end
      Process.kill('TERM', xvfb) rescue nil
      Process.wait(xvfb) rescue nil # synchronous teardown so display :99 is free for the next run
      Log.log "GUI launch probe: #{res}"
      c.smoke = "#{c.smoke} | GUI launch probe: #{res}"
    end

    # linked-libs vs RDEPEND (source only). '>' undeclared-but-linked = missing dep
    # the bump may need -> escalate. '<' declared-but-unused = advisory, not blocking.
    def qa_vdb
      c = @c
      return Log.log('qa-vdb skipped: prebuilt payload (dlopen-heavy, RDEPEND vs NEEDED too noisy)') if c.payload
      return Log.log('qa-vdb not installed (app-portage/iwdevtools) - linked-libs/RDEPEND check skipped') \
        if `command -v qa-vdb 2>/dev/null`.strip.empty?
      out = `qa-vdb #{c.pkg.shellescape} 2>&1`.scrub.gsub(/\e\[[0-9;]*m/, '')
      c.evidence.write('qa-vdb.txt', out)
      if out =~ /(^|\s)>(\s|$)/
        puts out
        raise Escalate.new('qa-vdb: linked lib missing from RDEPEND', c.evidence.dir)
      elsif out =~ /(^|\s)<(\s|$)/
        puts out.lines.select { |l| l =~ /(^|\s)<(\s|$)/ }.join
        Log.log 'qa-vdb: droppable dep(s) above - advisory, not blocking the bump (pre-existing hygiene)'
      else
        Log.ok 'qa-vdb: RDEPEND matches linked libs'
      end
    end

    # emerge non-zero: a timeout or a local dep-resolution gap is not a defect ->
    # defer (Abort, exit 2) so the sweep/CI retries; a real compile failure escalates.
    def emerge_failed(out, erc)
      c = @c
      puts out.lines.last(20).join
      if erc == 124
        raise Abort, "emerge timed out (>#{c.cfg.op_timeout}s): heavy build, not a defect. Deferring."
      end
      if out =~ /have been masked|masked packages|required to complete your request|no ebuilds to satisfy|Blocked Packages|not be installed|USE changes are necessary|autounmask/
        raise Abort, 'cannot smoke-test locally: dependency resolution needs a change here (overlay ~amd64 dep / PYTHON_TARGET / transitive USE). Not a bump defect; CI resolves it. Deferring.'
      end
      raise Escalate.new('emerge failed', c.evidence.dir)
    end
  end
end
