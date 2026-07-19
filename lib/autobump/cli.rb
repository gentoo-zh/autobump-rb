# frozen_string_literal: true
module Autobump
  # Dispatcher / full pipeline. Parses args, then runs the stages in order:
  #   locate -> classify -> [--check] -> preflight -> distfiles -> artifact_diff
  #   -> [--diff-only] -> build_test -> finalize -> pr
  # Escalate = exit 3, Abort = exit 2, clean return = 0. cleanup runs on failure once
  # the branch exists (ctx.armed), disarmed after the commit.
  class CLI
    def self.run(argv)
      o = parse(argv)
      cfg = Config.new rescue die($!.message) # e.g. "not inside a git checkout" -> exit 2, not 1
      pkg, newver, issue = o[:pkg], o[:newver], o[:issue]
      if issue
        begin
          pkg, newver = Issue.resolve(cfg, issue)
        rescue RuntimeError => e
          die e.message # gh/parse failure is a precondition defer (exit 2), not a crash
        end
        Log.log "issue ##{issue} -> #{pkg} -> #{newver}"
      end
      die 'need <issue#> or <cat/pkg> <newver>' unless pkg && newver
      o[:install] = true if o[:pr] # --pr always runs the full local test

      cat, pn = pkg.split('/', 2)
      pkgdir = File.join(cfg.repo, pkg)
      die "no such package dir: #{pkgdir}" unless Dir.exist?(pkgdir)
      begin
        loc = Locate.new(cfg.repo, pkg, newver)
      rescue RuntimeError => e
        die e.message
      end
      Log.log "current: #{loc.old_pvr}  ->  target: #{newver}"
      ev = Evidence.new(pn)
      ctx = Context.new(
        cfg: cfg, pkg: pkg, cat: cat, pn: pn, pkgdir: pkgdir, newver: newver, issue: issue,
        check: o[:check], install: o[:install], pr: o[:pr], diff_only: o[:diff_only],
        accept_surface: o[:accept_surface], accept_payload: o[:accept_payload], keep_old: o[:keep_old],
        old_ebuild: loc.old_ebuild, old_pvr: loc.old_pvr, old_pv: loc.old_pv,
        old_pvr_presync: loc.old_pvr, new_ebuild: loc.new_ebuild,
        branch: "#{cat}-#{pn}-#{newver}", evidence: ev, armed: false)

      # stage 2: classification (no branch yet -> escalate just prints + exits)
      res = begin
        Classify.new(cfg: cfg, pkg: pkg, old_ebuild: loc.old_ebuild,
                     old_pv: loc.old_pv, newver: newver, evidence: ev).run
      rescue => e # an unexpected classify error defers (exit 2), never exit 1 off the contract
        die "unexpected error during classification: #{e.class}: #{e.message}"
      end
      ctx.multiarch = res.multiarch
      ctx.gui = res.gui
      res.escalations.each { |n| puts "ESCALATE: #{n}" }
      unless res.escalations.empty?
        puts "== not mechanically safe; evidence: #{ev.dir} =="
        exit 3
      end
      Log.ok 'classification: mechanical bump candidate'
      if o[:check]
        puts "check-only: would bump #{pkg} #{loc.old_pvr} -> #{newver}"
        exit 0
      end

      # stages 3-8
      %w[INT TERM].each { |s| Signal.trap(s) { Cleanup.run(ctx) if ctx.armed; exit 130 } }
      begin
        Preflight.new(ctx).run
        Distfiles.new(ctx).run
        ArtifactDiff.new(ctx).run
        BuildTest.new(ctx).run
        Finalize.new(ctx).run
        PR.new(ctx).run
      rescue ArtifactDiff::DiffOnlyDone => e
        Cleanup.run(ctx) if ctx.armed
        puts "== diff-only: checks passed; evidence kept in #{e.dir} =="
        exit 0
      rescue Escalate => e
        Cleanup.run(ctx) if ctx.armed
        puts "== not mechanically safe (#{e.message}); evidence: #{e.dir || ev.dir} =="
        exit 3
      rescue Abort => e
        Cleanup.run(ctx) if ctx.armed
        die e.message
      rescue StandardError => e
        # any UNEXPECTED exception (not Escalate/Abort/DiffOnlyDone) must still run
        # cleanup so a branch / accept_keywords file is not orphaned, then defer
        # (exit 2) rather than crash (exit 1) off the 0/2/3 contract.
        Cleanup.run(ctx) if ctx.armed
        die "unexpected error: #{e.class}: #{e.message}"
      end
      puts "== done; evidence kept in #{ev.dir} =="
    end

    def self.parse(argv)
      o = { check: false, install: false, pr: false, diff_only: false,
            accept_surface: false, accept_payload: false, keep_old: false,
            pkg: nil, newver: nil, issue: nil }
      argv.each do |a|
        case a
        when '--check' then o[:check] = true
        when '--diff-only' then o[:diff_only] = true
        when '--accept-surface' then o[:accept_surface] = true
        when '--accept-payload' then o[:accept_payload] = true
        when '--install' then o[:install] = true
        when '--pr' then o[:pr] = true
        when '--keep-old' then o[:keep_old] = true                   # keep ALL prior versions
        when /\A--keep-old=(\d+)\z/ then o[:keep_old] = $1.to_i       # keep the N most-recent versions
        when %r{/} then o[:pkg] = a                                  # bash */*
        when /\A[0-9].*\.[0-9]/ then o[:newver] = a                  # bash [0-9]*.[0-9]*
        when /\A[0-9]/ # bash [0-9]* (any digit-led token: _pre/_beta/date versions)
          if o[:pkg].nil?
            die("issue must be a number: #{a}") unless a =~ /\A[0-9]+\z/ # the issue token is a bare issue number
            o[:issue] = a
          else
            o[:newver] = a
          end
        else die("unknown arg: #{a}")
        end
      end
      o
    end

    def self.die(m)
      warn "!! #{m}"
      exit 2
    end
  end
end
