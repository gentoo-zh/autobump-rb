# frozen_string_literal: true
require 'shellwords'
module Autobump
  # Env-driven config. Defaults work on a dev box (fork clone, sudo, separate live
  # overlay) and in CI (root, canonical checkout registered in place). Overlay-agnostic
  # -- not gentoo-zh-specific; point AUTOBUMP_REPO/AUTOBUMP_UPSTREAM_REPO anywhere.
  class Config
    attr_reader :repo, :distdir, :live_overlay, :upstream_repo, :sudo,
                :op_timeout, :separate_overlay, :push_remote, :bot_name, :bot_email

    def initialize(env: ENV)
      # treat an exported-but-empty value as unset, like shell ${VAR:-default}: Ruby `||`
      # only falls back on nil, so '' would slip through -- and AUTOBUMP_OP_TIMEOUT=''
      # then means `timeout 0` (no ceiling) and AUTOBUMP_REPO='' aborts.
      g = ->(k, d = nil) { v = env[k]; v.nil? || v.empty? ? d : v }
      @repo = g.('AUTOBUMP_REPO') || `git rev-parse --show-toplevel 2>/dev/null`.strip
      raise 'not inside a git checkout' if @repo.empty?
      @distdir       = g.('AUTOBUMP_DISTDIR',       '/var/cache/distfiles')
      @live_overlay  = g.('AUTOBUMP_LIVE_OVERLAY',  '/var/db/repos/gentoo-zh')
      @upstream_repo = g.('AUTOBUMP_UPSTREAM_REPO', 'gentoo-zh/overlay')
      @sudo          = Process.uid.zero? ? '' : 'sudo'
      # a garbled AUTOBUMP_OP_TIMEOUT must NOT silently become 0 (= no ceiling via
      # `timeout 0`); reject non-positive/non-numeric and fall back to the default.
      to = Integer(g.('AUTOBUMP_OP_TIMEOUT', '900'), exception: false)
      @op_timeout = (to && to.positive?) ? to : 900
      @push_remote   = g.('AUTOBUMP_PUSH_REMOTE', 'origin')
      @sync_remote_env = g.('AUTOBUMP_SYNC_REMOTE')
      @bot_name  = g.('AUTOBUMP_BOT_NAME')
      @bot_email = g.('AUTOBUMP_BOT_EMAIL')
      # separate checkout (dev box) vs same tree as REPO (CI). Compare by realpath.
      @separate_overlay = Dir.exist?(@live_overlay) &&
        (File.realpath(@live_overlay) rescue nil) != (File.realpath(@repo) rescue nil)
    end

    # The remote whose fetch URL IS owner/repo. Substring matching would take a mirror
    # (".../gentoo-zh/overlay-mirror.git") for the canonical repo and sync master from it.
    def self.remote_named(remote_v, upstream_repo)
      want = upstream_repo.downcase
      remote_v.lines.each do |line|
        name, url, kind = line.split
        next unless kind == '(fetch)' && url
        slug = url.sub(/\.git\z/, '').sub(%r{/\z}, '').downcase[%r{([^/:]+/[^/]+)\z}, 1]
        return name if slug == want
      end
      nil
    end

    # Pick the CANONICAL remote to sync master from (never blindly `origin`).
    # Honour AUTOBUMP_SYNC_REMOTE, else the remote whose URL is upstream_repo,
    # else add a throwaway `autobump-canonical`. Memoized; called at preflight
    # (not construction) so --check never touches remotes.
    def sync_remote
      @sync_remote ||= begin
        r = @sync_remote_env
        r ||= Config.remote_named(`git -C #{@repo.shellescape} remote -v`, @upstream_repo)
        unless r
          url = "https://github.com/#{@upstream_repo}.git"
          have = `git -C #{@repo.shellescape} remote`.lines.map(&:strip).include?('autobump-canonical')
          if have
            system('git', '-C', @repo, 'remote', 'set-url', 'autobump-canonical', url)
          else
            system('git', '-C', @repo, 'remote', 'add', 'autobump-canonical', url)
          end
          r = 'autobump-canonical'
        end
        r
      end
    end
  end
end
