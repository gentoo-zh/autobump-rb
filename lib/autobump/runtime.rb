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
    :rewrite_var, :rewrite_url, :rewrite_regex, :copied_ebuild,
    keyword_init: true
  ) do
    # run a command; return [combined stdout+stderr, ok?, exit_code]. Array form (never a
    # shell), so args need no quoting. LC_ALL=C is a deliberate determinism aid for the
    # ebuild/emerge output this helper parses: QA-notice / soname text must not be
    # locale-translated, or the regexes below would miss it.
    #
    # The command runs in its own process group and the timeout signals the GROUP: `timeout`
    # only kills the process it supervises, so an emerge that overran left its build running
    # as root while cleanup restored the checkout underneath it. Exit code 124 is kept for a
    # timeout so callers can still tell it from a real failure.
    def sh(*a, sudo: false, timeout: nil)
      cmd = a.dup
      cmd.unshift(cfg.sudo) if sudo && !cfg.sudo.empty?
      read, write = IO.pipe
      pid = Process.spawn({ 'LC_ALL' => 'C' }, *cmd.compact, out: write, err: %i[child out], pgroup: true)
      write.close
      output = +''
      drain = Thread.new { output << read.read } # a full pipe would deadlock the wait below
      code = wait_for(pid, timeout)
      drain.join
      read.close
      [output, code.zero?, code]
    rescue SystemCallError => e
      # a failed fork/exec (ENOENT/EAGAIN/EMFILE) must degrade to ok=false -> Abort,
      # never crash the process (exit 1) and skip cleanup.
      ["#{cmd.compact.join(' ')}: #{e.message}", false, 127]
    end

    KILL_GRACE = 10

    def wait_for(pid, timeout)
      deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
      loop do
        done, status = Process.wait2(pid, Process::WNOHANG)
        return status.exitstatus || (128 + (status.termsig || 0)) if done
        if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          end_group(pid) # may already have reaped it while waiting out the grace period
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            nil
          end
          return 124
        end
        sleep 0.1
      end
    end

    # The children may be root (sudo), and a non-root parent cannot signal them directly.
    def reaped?(pid)
      !Process.wait(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end

    def end_group(pid)
      %w[TERM KILL].each do |signal|
        begin
          Process.kill("-#{signal}", pid)
        rescue Errno::EPERM, Errno::ESRCH
          system(*[cfg.sudo, 'kill', "-#{signal}", "-#{pid}"].reject { |x| x.nil? || x.empty? },
                 out: File::NULL, err: File::NULL)
        end
        return if signal == 'KILL'

        KILL_GRACE.times do
          return if reaped?(pid)

          sleep 1
        end
      end
    end
  end
end
