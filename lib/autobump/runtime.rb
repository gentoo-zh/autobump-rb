# frozen_string_literal: true
require 'tempfile'
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
    :rewrite_var, :rewrite_url, :rewrite_regex, :copied_ebuild, :bundles,
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
    #
    # Output goes to a file, not a pipe: a descendant that left the group (an Electron app a
    # wrapper script starts under setsid) kept the pipe open, so reading to EOF never returned
    # and the job hung until its own timeout. stderr_only keeps stderr and drops stdout.
    def sh(*a, sudo: false, timeout: nil, stderr_only: false, **spawn_opts)
      cmd = a.dup
      cmd.unshift(cfg.sudo) if sudo && !cfg.sudo.empty?
      Tempfile.create('autobump-sh-') do |file|
        file.close
        path = File.realpath(file.path)
        streams = stderr_only ? { out: File::NULL, err: [path, 'w'] } : { out: [path, 'w'], err: %i[child out] }
        pid = Process.spawn({ 'LC_ALL' => 'C' }, *cmd.compact, **streams, **spawn_opts, pgroup: true)
        code = wait_for(pid, timeout)
        end_leftovers(pid, path)
        [File.read(path), code.zero?, code]
      end
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
        signal_group(signal, pid)
        return if signal == 'KILL'

        KILL_GRACE.times do
          return if reaped?(pid)

          sleep 1
        end
      end
    end

    def signal_group(signal, pgid)
      Process.kill("-#{signal}", pgid)
    rescue Errno::EPERM, Errno::ESRCH
      system(*[cfg.sudo, 'kill', "-#{signal}", "-#{pgid}"].reject { |x| x.nil? || x.empty? },
             out: File::NULL, err: File::NULL)
    end

    # Whatever the command left running once it returned: the rest of its group, and every
    # group that still holds its output file, which catches a process that left through setsid.
    # Left alone they keep running in the container.
    def end_leftovers(pid, path)
      groups = ([pid] + output_holders(path).filter_map { |p| Process.getpgid(p) rescue nil }).uniq
      groups -= [Process.getpgrp]
      %w[TERM KILL].each do |signal|
        groups.select! { |g| group_alive?(g) }
        return if groups.empty?

        groups.each { |g| signal_group(signal, g) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE
        sleep 0.1 while groups.any? { |g| group_alive?(g) } &&
                        Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      end
    end

    def output_holders(path)
      Dir.glob('/proc/[0-9]*/fd/*').filter_map do |fd|
        fd[%r{\A/proc/(\d+)/}, 1].to_i if (File.readlink(fd) rescue nil) == path
      end.uniq - [Process.pid]
    end

    def group_alive?(pgid)
      Process.kill(0, -pgid)
      true
    rescue Errno::EPERM
      true
    rescue Errno::ESRCH
      false
    end
  end
end
