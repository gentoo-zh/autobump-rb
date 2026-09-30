# frozen_string_literal: true
require 'json'
require 'time'
module Autobump
  # The bundle controller's snapshot (overlay scripts/bundles.py, schema 1), read with
  # --bundle-status. It says which release of which drafts / gentoo-deps repo carries this
  # bump's vendor bundles and how far their producers got. The engine never asks GitHub:
  # the snapshot is the only evidence, and a 404 on a URI it covers is judged from it.
  class BundleStatus
    SCHEMA = 1
    STATES = %w[ready pending unknown escalate].freeze
    PRODUCER_STATUSES = %w[queued in_progress completed missing].freeze
    # GitHub's run conclusions; only success is success evidence
    CONCLUSIONS = [nil, *%w[success failure cancelled skipped timed_out neutral action_required stale startup_failure]].freeze
    # a release upload lands a little after its producer run reports success
    SETTLE = 15 * 60

    Bundle = Struct.new(:id, :repo, :release_tag, :state, :producers, :release_url, keyword_init: true) do
      def prefix = "https://github.com/#{repo}/releases/download/#{release_tag}/"
      def page = release_url || "https://github.com/#{repo}"
    end

    # One covered-404 judgement: exit 2 or 3, the reason, and the fields the sweep reads.
    Decision = Struct.new(:exit_code, :reason, :result, keyword_init: true)

    attr_reader :package, :version, :bundles

    def self.load(path, package:, version:, clock: -> { Time.now })
      raise Abort, "--bundle-status: no such file: #{path}" unless File.file?(path)
      doc = begin
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError, SystemCallError, ArgumentError => e
        raise Abort, "--bundle-status: #{path} is not readable JSON: #{e.message}"
      end
      new(doc, package: package, version: version, clock: clock, source: path)
    end

    def initialize(doc, package:, version:, clock: -> { Time.now }, source: 'snapshot')
      @package, @version, @clock = package, version, clock
      invalid = ->(m) { raise Abort, "--bundle-status: #{source}: #{m}" }
      invalid.call('not a JSON object') unless doc.is_a?(Hash)
      invalid.call("schema #{doc['schema'].inspect}, want #{SCHEMA}") unless doc['schema'] == SCHEMA
      invalid.call('targets is not a list') unless doc['targets'].is_a?(Array)
      target = doc['targets'].find { |t| t.is_a?(Hash) && t['package'] == package && t['version'] == version }
      invalid.call("no target for #{package} #{version}") unless target
      list = target['bundles']
      invalid.call("target #{package} #{version} lists no bundles") unless list.is_a?(Array) && !list.empty?
      @bundles = list.map { |b| bundle(b, invalid) }
    end

    # Every bundle whose release this URI downloads from. Host, repo and tag must match
    # exactly: a looser match would read an upstream release 404 as a bundle still building.
    # Bundles sharing a release come back in a fixed order, so the snapshot's array order
    # cannot change the judgement.
    def covering_all(uri)
      @bundles.select do |b|
        file = uri.delete_prefix(b.prefix)
        file != uri && !file.empty? && !file.include?('/')
      end.sort_by { |b| [b.id.to_s, b.state, b.release_url.to_s, JSON.generate(b.producers)] }
    end

    def covering(uri) = covering_all(uri).first
    def covers_all?(uris) = !uris.empty? && uris.all? { |u| covering(u) }

    # Judge the 404s of covered URIs. Worst wins: one escalating URI escalates the fetch.
    def judge(uris)
      now = @clock.call
      decisions = uris.map { |u| judge_one(u, covering_all(u), now) }
      worst = decisions.find { |d| d.exit_code == 3 } || decisions.first
      reason = decisions.select { |d| d.exit_code == worst.exit_code }.map(&:reason).uniq.join('; ')
      Decision.new(exit_code: worst.exit_code, reason: reason,
                   result: { 'bundle' => true, 'exit' => worst.exit_code, 'reason' => reason,
                             'package' => @package, 'version' => @version,
                             'uris' => uris, 'bundles' => decisions.flat_map(&:result).uniq })
    end

    private

    def bundle(b, invalid)
      invalid.call('a bundle is not an object') unless b.is_a?(Hash)
      repo, tag, state, producers = b['repo'], b['release_tag'], b['state'], b['producers']
      invalid.call("bundle repo #{repo.inspect} is not owner/name") unless repo.is_a?(String) && repo.match?(%r{\A[\w.-]+/[\w.-]+\z})
      invalid.call("bundle #{repo} has no release_tag") unless tag.is_a?(String) && !tag.empty? && !tag.include?('/')
      invalid.call("bundle #{repo} state #{state.inspect}") unless STATES.include?(state)
      invalid.call("bundle #{repo} producers is not a list") unless producers.is_a?(Array) && producers.all?(Hash)
      producers.each { |p| producer(p, repo, invalid) }
      Bundle.new(id: b['id'], repo: repo, release_tag: tag, state: state, producers: producers,
                 release_url: b['release_url'])
    end

    def producer(p, repo, invalid)
      bad = ->(field) { invalid.call("bundle #{repo} producer #{field} #{p[field].inspect}") }
      bad.call('workflow') unless p['workflow'].is_a?(String) && !p['workflow'].empty?
      bad.call('status') unless PRODUCER_STATUSES.include?(p['status'])
      bad.call('conclusion') unless CONCLUSIONS.include?(p['conclusion'])
      bad.call('run_url') unless p['run_url'].nil? || p['run_url'].is_a?(String)
      at = p['completed_at']
      return if at.nil?
      begin
        Time.iso8601(at.to_s)
      rescue ArgumentError
        invalid.call("bundle #{repo} producer completed_at #{at.inspect} is not ISO 8601")
      end
    end

    # Bundles sharing a release are judged on the union of their evidence: the release is
    # only complete when every producer of every one of them is.
    def judge_one(uri, bundles, now)
      b = bundles.first
      page = bundles.filter_map(&:release_url).min || b.page
      producers = bundles.flat_map(&:producers)
      active = producers.select { |p| %w[queued in_progress].include?(p['status']) }
      done = producers.select { |p| p['status'] == 'completed' && p['conclusion'] == 'success' }
      if bundles.any? { |x| %w[pending unknown].include?(x.state) } || !active.empty?
        run = (active.first || producers.first || {})['run_url'] || page
        return decision(2, "bundle pending: #{b.repo}@#{b.release_tag} (#{run})", bundles, run)
      end
      if done.empty? || done.length != producers.length
        return decision(3, "bundle asset missing, no successful producer: #{uri} (#{page})", bundles, page)
      end
      # a success with no completion time cannot be timed against the settle window
      if (untimed = done.find { |p| p['completed_at'].nil? })
        run = untimed['run_url'] || page
        return decision(2, "bundle pending: #{b.repo}@#{b.release_tag} (#{run}); producer completion time unknown",
                        bundles, run)
      end
      last = done.max_by { |p| Time.iso8601(p['completed_at']) }
      run = last['run_url'] || page
      if now - Time.iso8601(last['completed_at']) < SETTLE
        decision(2, "bundle pending: #{b.repo}@#{b.release_tag} (#{run}); producer finished under 15 min ago", bundles, run)
      else
        decision(3, "bundle asset missing: #{uri} (#{run})", bundles, run)
      end
    end

    def decision(code, reason, bundles, run)
      Decision.new(exit_code: code, reason: reason,
                   result: bundles.map do |b|
                     { 'id' => b.id, 'repo' => b.repo, 'release_tag' => b.release_tag,
                       'state' => b.state, 'run_url' => run }
                   end)
    end
  end
end
