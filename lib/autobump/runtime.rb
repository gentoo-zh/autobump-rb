# frozen_string_literal: true
module Autobump
  # Exit-code semantics -- the contract the whole engine lives on:
  #   Abort    -> exit 2  (precondition failed, or a TRANSIENT defer the sweep retries)
  #   Escalate -> exit 3  (not mechanically safe; a judge reads the evidence pack)
  # 0 is a clean return. cleanup runs on any failure once the branch exists.
  class Abort < StandardError; end
  class Escalate < StandardError
    attr_reader :dir
    def initialize(msg, dir = nil)
      super(msg)
      @dir = dir
    end
  end

  module Log
    module_function
    def log(m) = puts(">> #{m}")
    def ok(m)  = puts("ok #{m}")
  end

  # Shared pipeline context threaded through every stage.
  Context = Struct.new(
    :cfg, :pkg, :cat, :pn, :pkgdir, :newver, :issue,
    :check, :install, :pr, :diff_only, :accept_surface, :accept_payload,
    :old_ebuild, :old_pvr, :old_pv, :old_pvr_presync, :new_ebuild, :branch, :evidence,
    :multiarch, :gui, :payload, :smoke, :armed, :old_distfile_missing, :keep_old,
    keyword_init: true
  ) do
    # run a command; return [combined stdout+stderr, ok?, exit_code]. Ordering is
    # `timeout N sudo cmd...` (sudo inner, timeout outer) so the timeout also bounds a
    # command that re-prompts. Array form (never a shell), so args need no quoting.
    # LC_ALL=C is a deliberate determinism aid for the ebuild/emerge output this
    # helper parses: QA-notice / soname text must not be locale-translated, or the
    # regexes below would miss it.
    def sh(*a, sudo: false, timeout: nil)
      cmd = a.dup
      cmd.unshift(cfg.sudo) if sudo && !cfg.sudo.empty?
      cmd.unshift('timeout', timeout.to_s) if timeout
      r = IO.popen({ 'LC_ALL' => 'C' }, cmd.compact, err: [:child, :out], &:read)
      code = $?.exitstatus || (128 + ($?.termsig || 0)) # signal-killed has nil exitstatus
      [r, $?.success?, code] # 3rd element lets a caller tell a 124 timeout from a real failure; `out, ok =` ignores it
    rescue SystemCallError => e
      # a failed fork/exec (ENOENT/EAGAIN/EMFILE) must degrade to ok=false -> Abort,
      # never crash the process (exit 1) and skip cleanup.
      ["#{cmd.compact.join(' ')}: #{e.message}", false, 127]
    end
  end
end
