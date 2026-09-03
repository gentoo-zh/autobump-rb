# frozen_string_literal: true
module Autobump
  # Version comparison as PMS defines it, in Ruby. `sort -V` disagrees with portage on suffixes
  # -- it ranks 1.2.3_rc1 above 1.2.3 -- which turns a real downgrade into a mechanical bump and a
  # legitimate prerelease-to-final bump into a "not newer" escalation. Portage itself is not
  # available everywhere this runs (the engine's own CI is a plain runner), so the ordering lives
  # here rather than in a shell-out that silently answers differently when it is missing.
  module Version
    module_function

    SUFFIX_RANK = { 'alpha' => 0, 'beta' => 1, 'pre' => 2, 'rc' => 3, '' => 4, 'p' => 5 }.freeze
    PARSE = /\A(?<numbers>\d+(?:\.\d+)*)(?<letter>[a-z]?)(?<suffixes>(?:_(?:alpha|beta|pre|rc|p)\d*)*)(?:-r(?<revision>\d+))?\z/

    def newer?(a, b) = compare(a, b).positive?

    # -1, 0 or 1. An unparseable version falls back to a component-wise numeric compare, which is
    # what portage would refuse outright; the caller only ever asks about versions portage accepted.
    def compare(a, b)
      pa = parse(a)
      pb = parse(b)
      return fallback(a, b) if pa.nil? || pb.nil?

      by_numbers(pa[:numbers], pb[:numbers]).then { |c| return c unless c.zero? }
      (pa[:letter] <=> pb[:letter]).then { |c| return c unless c.zero? }
      by_suffixes(pa[:suffixes], pb[:suffixes]).then { |c| return c unless c.zero? }
      pa[:revision] <=> pb[:revision]
    end

    def parse(version)
      m = PARSE.match(version.to_s)
      return nil unless m

      { numbers: m[:numbers].split('.'), letter: m[:letter], revision: m[:revision].to_i,
        suffixes: m[:suffixes].scan(/_([a-z]+)(\d*)/).map { |name, number| [SUFFIX_RANK[name], number.to_i] } }
    end

    # The first component is a plain integer; a later one with a leading zero is a fraction, so
    # 1.1 > 1.02 while 1.10 > 1.9 (PMS 3.3).
    def by_numbers(a, b)
      cmp = a.first.to_i <=> b.first.to_i
      return cmp unless cmp.zero?

      [a.length, b.length].max.pred.times do |i|
        x = a[i + 1]
        y = b[i + 1]
        return -1 if x.nil?
        return 1 if y.nil?

        cmp = if x.start_with?('0') || y.start_with?('0')
                x.sub(/0+\z/, '') <=> y.sub(/0+\z/, '')
              else
                x.to_i <=> y.to_i
              end
        return cmp unless cmp.zero?
      end
      0
    end

    # No suffix ranks above _rc and below _p, so a missing entry compares as that.
    def by_suffixes(a, b)
      none = [SUFFIX_RANK[''], 0]
      [a.length, b.length].max.times do |i|
        cmp = (a[i] || none) <=> (b[i] || none)
        return cmp unless cmp.zero?
      end
      0
    end

    def fallback(a, b)
      x = a.to_s.scan(/\d+/).map(&:to_i)
      y = b.to_s.scan(/\d+/).map(&:to_i)
      (x <=> y) || (a.to_s <=> b.to_s)
    end

    # The release ebuilds git tracks in a package dir, newest last. Untracked files are left out
    # on purpose: a maintainer's local draft must not become the ebuild a bump copies from. Only a
    # git that could not answer at all falls back to the filesystem.
    def release_ebuilds(repo, pkgdir)
      listed, ok = git_ls(repo, pkgdir)
      files = if ok
                listed.lines.map(&:chomp).reject(&:empty?).map { |f| File.join(repo, f) }
              else
                Dir.glob(File.join(pkgdir, '*.ebuild'))
              end
      releases = files.reject { |f| f =~ /-9{4,}\.ebuild\z/ }
      releases.sort { |x, y| compare(pv_of(x), pv_of(y)) }
    end

    def git_ls(repo, pkgdir)
      out = IO.popen(['git', '-C', repo, 'ls-files', '--', "#{pkgdir}/*.ebuild"], err: File::NULL, &:read)
      [out.to_s, $?&.success? || false]
    rescue SystemCallError
      ['', false] # no git at all: the filesystem is all there is
    end

    def pv_of(path)
      File.basename(path, '.ebuild')[/-(\d[^-]*(?:-r\d+)?)\z/, 1].to_s
    end
  end
end
