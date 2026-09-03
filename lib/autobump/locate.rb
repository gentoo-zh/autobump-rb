# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Stage 1: locate the current release ebuild and derive versions. Uses portage's
  # own version ordering (ls | grep -vE '-9{4,}' | sort -V | tail -1) and drops 9999
  # live ebuilds, so the highest real release is always the bump base.
  class Locate
    attr_reader :old_ebuild, :old_pvr, :old_pv, :new_ebuild, :pn, :cat
    def initialize(repo, pkg, newver)
      @cat, @pn = pkg.split('/', 2)
      pkgdir = File.join(repo, pkg)
      raise "no such package dir: #{pkgdir}" unless Dir.exist?(pkgdir)
      @old_ebuild = Version.release_ebuilds(repo, pkgdir).last.to_s
      raise "no release ebuild in #{pkgdir} (live-only package?)" if @old_ebuild.empty?
      @old_pvr = File.basename(@old_ebuild, '.ebuild').sub(/\A#{Regexp.escape(@pn)}-/, '')
      @old_pv  = @old_pvr.sub(/-r[0-9]+\z/, '')
      @new_ebuild = File.join(pkgdir, "#{@pn}-#{newver}.ebuild")
      raise "already at #{newver}" if @old_pv == newver
      raise "#{@new_ebuild} already exists" if File.exist?(@new_ebuild)
    end
  end
end
