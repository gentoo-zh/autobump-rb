# frozen_string_literal: true
module Autobump
  # Undo a failed bump: unstage, remove the copied ebuild, restore the tree, drop the
  # branch, remove --install spillover (the accept_keywords file and any live-overlay
  # copy). Every step is a safe no-op if the stage that created it never ran.
  module Cleanup
    module_function
    def run(ctx)
      cfg = ctx.cfg; repo = cfg.repo
      quiet = { out: File::NULL, err: File::NULL } # array form -> no shell, no quoting needed
      g = ->(*args) { system('git', '-C', repo, *args, **quiet) }
      g.('reset', '-q', '--', ctx.pkgdir) if ctx.pkgdir
      # only the copy this run made: the path can also hold a maintainer's draft, or another
      # run's work in the same checkout
      File.delete(ctx.new_ebuild) if ctx.copied_ebuild && File.exist?(ctx.new_ebuild)
      g.('checkout', '-q', '--', ctx.pkgdir) if ctx.pkgdir
      system('git', '-C', repo, 'checkout', '-q', 'master') # let this step's stderr show
      g.('branch', '-qD', ctx.branch) if ctx.branch
      rm = ->(path) { system(*[cfg.sudo, 'rm', '-f', path].reject { |x| x.nil? || x.empty? }, **quiet) }
      rm.("/etc/portage/package.accept_keywords/autobump-#{ctx.pn}") if ctx.pn
      if cfg.separate_overlay && ctx.pn && ctx.newver
        rm.("#{cfg.live_overlay}/#{ctx.pkg}/#{ctx.pn}-#{ctx.newver}.ebuild")
      end
    end
  end
end
