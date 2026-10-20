# frozen_string_literal: true
module Autobump
  # Stage 5b: toolchain floors. A new upstream that raises its Go or Rust floor still builds here,
  # because the build host has the newest compiler, so the copied ebuild would ship a floor that
  # is too low for anyone on an older toolchain. Read the floor from the new source tree and keep
  # the ebuild in step: raise an explicit `>=dev-lang/go-X` atom or `RUST_MIN_VER` in place, and
  # escalate when the atom cannot be rewritten safely or ::gentoo has no compiler new enough.
  # A floor the ebuild does not state (no atom, no RUST_MIN_VER) or a bump whose vendor bundle
  # is regenerated is not edited: the bump builds as before, and a note in accepted_diffs makes
  # the PR a draft so a human adds the dependency. Only ever raises; never adds an upper bound,
  # never touches RUST_MAX_VER. Runs after the artifact diff unpacked the new tree, before the build test, so
  # the build uses the rewritten ebuild.
  class Toolchain
    Plan = Struct.new(:action, :text, :note, :reason, keyword_init: true) do
      def self.none = new(action: :none)
      def self.escalate(reason) = new(action: :escalate, reason: reason)
      # left for a human on the draft PR: the bump builds, but the ebuild states too low a floor
      def self.note(note) = new(action: :note, note: note)
    end

    GO_DIRECTIVE = %r{^[ \t]*go[ \t]+([^\s/]+)[ \t]*(?://.*)?$}
    GO_VERSION = /\A(\d+)\.(\d+)(?:\.(\d+))?(?:(rc|beta)(\d+))?\z/
    # An atom naming dev-lang/go itself, not dev-lang/go-bootstrap: the name (and version) must
    # end at a delimiter.
    GO_ATOM = %r{(?<![\w/.+-])(?<block>!{1,2})?(?<op>>=|<=|>|<|~|=)?dev-lang/go(?:-(?<ver>\d[\w.*]*(?:-r\d+)?))?(?=[\s:\[\]"')]|\z)}
    RUST_MIN_SET = /(?<![\w$])RUST_MIN_VER=/
    RUST_MIN = /\A([ \t]*)RUST_MIN_VER=(["']?)(\d[\d.]*)\2[ \t]*\z/

    # 1.26 and 1.26.0 name the same floor; PMS ranks the shorter one lower, which would turn an
    # equal floor into a raise.
    def self.pad(version)
      version.to_s.sub(/\A\d+(?:\.\d+)*/) { |n| (n.split('.') + %w[0 0]).first([n.count('.') + 1, 3].max).join('.') }
    end

    def self.compare(a, b) = Version.compare(pad(a), pad(b))

    # [the go.mod line, the floor as a portage version]; the `toolchain` line only names what
    # `go` downloads when the local one is older, so it is no floor. 1.27rc1 is go-1.27.0_rc1.
    def self.go_directive(gomod)
      gomod.to_s.each_line do |line|
        next unless (m = GO_DIRECTIVE.match(line.chomp))
        v = GO_VERSION.match(m[1])
        return [line.strip, nil] unless v
        ver = "#{v[1]}.#{v[2]}.#{v[3] || 0}"
        ver += "_#{v[4]}#{v[5]}" if v[4]
        return [line.strip, ver]
      end
      nil
    end

    # A line without its comment; offsets into it are offsets into the line.
    def self.code_of(line) = line.sub(/(?:\A|(?<=[ \t]))#.*/m, '')

    # Every dev-lang/go atom outside comments, blockers left out: [line index, MatchData].
    def self.go_atoms(text)
      text.lines.each_with_index.flat_map do |line, i|
        code_of(line).to_enum(:scan, GO_ATOM).map { [i, Regexp.last_match] }.reject { |_, m| m[:block] }
      end
    end

    # Whether an atom other than a lower bound rules out the required version.
    def self.excludes?(m, required)
      ver = m[:ver] or return false
      case m[:op]
      when '<' then compare(required, ver) >= 0
      when '<=' then compare(required, ver) > 0
      when '=' then ver.end_with?('*') ? !pad(required).start_with?(ver.chomp('*')) : compare(required, ver) != 0
      when '~' then compare(required.sub(/-r\d+\z/, ''), ver.sub(/-r\d+\z/, '')) != 0
      else false
      end
    end

    def self.go_module?(text) = inherits?(text, 'go-module')
    def self.go_package?(text) = go_module?(text) || !go_atoms(text).empty?
    def self.rust_package?(text) = inherits?(text, 'cargo') || inherits?(text, 'rust') || text.match?(/^[ \t]*RUST_MIN_VER=/)

    def self.inherits?(text, eclass)
      text.gsub(/\\\n/, ' ').lines.any? { |l| l =~ /\A[ \t]*inherit[ \t]/ && l.split.include?(eclass) }
    end

    # required: the go.mod floor; line: the go.mod line it came from; eclass_floor: the version
    # go-module.eclass puts in BDEPEND; best: the best dev-lang/go the tree offers.
    def self.go_plan(text, required:, line:, eclass_floor:, best:, rewrite: true)
      atoms = go_atoms(text)
      floors = atoms.select { |_, m| m[:op] == '>=' && m[:ver] }
      above = atoms.select { |_, m| m[:op] == '>' && m[:ver] }
      conflicts = atoms.select { |_, m| excludes?(m, required) }
      # the eclass BDEPEND applies beside any atom the ebuild adds, so the higher of the two holds
      lows = (floors + above).map { |_, m| m[:ver] }
      lows << eclass_floor if go_module?(text)
      floor = lows.max { |a, b| compare(a, b) }
      if conflicts.empty?
        return Plan.none if floor && compare(required, floor) <= 0
        # a bare dev-lang/go outside go-module states no floor to keep in step
        return Plan.none if floor.nil? && best && compare(required, best) <= 0
      end
      if best.nil? || compare(required, best) > 0
        return Plan.escalate("go.mod needs Go #{required} (#{line}), above the best dev-lang/go in ::gentoo " \
                             "(#{best || 'none visible'}); the bump cannot build until it lands")
      end
      unless conflicts.empty?
        spelled = conflicts.map { |_, m| m[0] }.uniq.join(', ')
        return Plan.escalate("go.mod needs Go #{required} (#{line}), which the ebuild's #{spelled} rules out")
      end
      if floors.empty? && above.empty?
        return Plan.note("go.mod requires go #{required} (#{line}), above the go-module.eclass floor " \
                         "#{eclass_floor}, and the ebuild has no >=dev-lang/go atom; add " \
                         ">=dev-lang/go-#{required}:= to BDEPEND")
      end
      unless floors.size == 1 && above.empty?
        spelled = (floors + above).map { |_, m| m[0] }.uniq.join(', ')
        return Plan.escalate("go.mod raises the Go floor to #{required} (#{line}), and the ebuild's lower " \
                             "bounds (#{spelled}) are not one >=dev-lang/go atom to raise")
      end
      i, m = floors.first
      unless rewrite
        return Plan.note("go.mod requires go #{required} (#{line}), above #{m[0]}; this bump's vendor bundle " \
                         "is regenerated, so the atom is not rewritten here; raise it to #{required}")
      end
      lines = text.lines
      lines[i] = lines[i][0...m.begin(:ver)] + required + lines[i][m.end(:ver)..]
      Plan.new(action: :rewrite, text: lines.join,
               note: "go floor raised: #{m[:ver]} -> #{required} (go.mod: #{line})")
    end

    # The floor a Cargo.toml pair states: the package's own rust-version, or the workspace's when
    # the package inherits it or sets none. [the line, the version], or nil.
    def self.cargo_rust_version(pkg_toml, ws_toml)
      found = [toml_value(pkg_toml, 'package', 'rust-version'),
               toml_value(ws_toml, 'workspace.package', 'rust-version')].compact
      found.max { |(_, a), (_, b)| compare(a, b) }
    end

    # [line, value] of a literal `key = "x.y"` in [section]; `key.workspace = true` is no literal.
    def self.toml_value(toml, section, key)
      current = nil
      toml.to_s.each_line do |line|
        if line.match?(/\A[ \t]*\[\[/)
          current = nil # an array of tables such as [[bin]]
        elsif (h = line[/\A[ \t]*\[([^\[\]]+)\][ \t]*(?:#.*)?$/, 1])
          current = h.strip
        elsif current == section && (v = line[/\A[ \t]*#{Regexp.escape(key)}[ \t]*=[ \t]*["'](\d+(?:\.\d+){1,2})["']/, 1])
          return [line.strip, v]
        end
      end
      nil
    end

    # Every RUST_MIN_VER assignment outside comments: [line index, literal value or nil, indented].
    # Only an unindented literal is one this engine rewrites; an indented one sits in a conditional.
    def self.rust_min_sets(text)
      text.lines.each_with_index.filter_map do |line, i|
        code = code_of(line).chomp
        next unless code.match?(RUST_MIN_SET)
        m = RUST_MIN.match(code)
        [i, m&.[](3), m.nil? || !m[1].empty?]
      end
    end

    # The RUST_MIN_VER in force: the eclass default when unset, the lowest literal when every
    # assignment is one, nil when one is not.
    def self.rust_floor(sets, eclass_default)
      return eclass_default if sets.empty?
      vals = sets.map { |_, v, _| v }
      vals.all? ? vals.min { |a, b| compare(a, b) } : nil
    end

    # eclass_default: the oldest slot rust.eclass falls back to when RUST_MIN_VER is unset.
    def self.rust_plan(text, required:, line:, eclass_default:, best:, rewrite: true)
      sets = rust_min_sets(text)
      max = text[/^[ \t]*RUST_MAX_VER=["']?(\d[\d.]*)/, 1]
      floor = rust_floor(sets, eclass_default)
      return Plan.none if floor && compare(required, floor) <= 0
      if best.nil? || compare(required, best) > 0
        return Plan.escalate("Cargo.toml needs Rust #{required} (#{line}), above the best dev-lang/rust or " \
                             "rust-bin in ::gentoo (#{best || 'none visible'}); the bump cannot build until it lands")
      end
      if sets.empty?
        return Plan.note("Cargo.toml requires rust #{required} (#{line}), above rust.eclass's oldest slot " \
                         "#{eclass_default}, and the ebuild sets no RUST_MIN_VER; add RUST_MIN_VER=\"#{required}\"")
      end
      unless sets.size == 1 && sets.first[1] && !sets.first[2]
        spelled = sets.map { |i, _| text.lines[i].strip }.join(' | ')
        return Plan.escalate("Cargo.toml raises the Rust floor to #{required} (#{line}), and RUST_MIN_VER is not " \
                             "one unindented literal assignment to raise in place (#{spelled})")
      end
      if max && compare(required, max) > 0
        return Plan.escalate("Cargo.toml needs Rust #{required} (#{line}), above RUST_MAX_VER=#{max}")
      end
      unless rewrite
        return Plan.note("Cargo.toml requires rust #{required} (#{line}), above RUST_MIN_VER=#{floor}; this " \
                         "bump's vendor bundle is regenerated, so it is not rewritten here; raise it to #{required}")
      end
      lines = text.lines
      i = sets.first[0]
      lines[i] = lines[i].sub(/(RUST_MIN_VER=["']?)#{Regexp.escape(floor)}/) { "#{$1}#{required}" }
      Plan.new(action: :rewrite, text: lines.join,
               note: "rust floor raised: RUST_MIN_VER #{floor} -> #{required} (Cargo.toml: #{line})")
    end

    # Neither S nor the workspace states a rust-version (a virtual workspace, or S without a
    # Cargo.toml), but members do. Which member the ebuild builds is not known here, so a member
    # above the floor only leaves a note. members: [[path, line, version]].
    def self.member_plan(text, members:, eclass_default:)
      return Plan.none if members.empty?
      path, line, ver = members.max { |a, b| compare(a[2], b[2]) }
      sets = rust_min_sets(text)
      floor = rust_floor(sets, eclass_default) || eclass_default
      return Plan.none if compare(ver, floor) <= 0
      stated = sets.empty? ? "rust.eclass's oldest slot #{eclass_default}" : "RUST_MIN_VER=#{floor}"
      Plan.note("workspace member #{path} requires rust #{pad(ver)} (#{line}), above #{stated}; the package's own " \
                'rust-version could not be read, so check which member the ebuild builds')
    end

    def self.eclass_go_floor(eclass) = eclass.to_s[/^[ \t]*BDEPEND=">=dev-lang\/go-(\d[\d.]*)/, 1]

    def self.eclass_rust_default(eclass)
      list = eclass.to_s[/_RUST_SLOTS_ORDERED=\(\s*(.*?)\)/m, 1] or return nil
      list.scan(/"(\d[\d.]*)"/).flatten.last
    end

    def initialize(ctx) = (@c = ctx)

    def run
      c = @c
      if c.payload
        Log.log 'toolchain floors: prebuilt payload, not checked'
        return
      end
      text = File.read(c.new_ebuild, encoding: 'UTF-8').scrub
      go = self.class.go_package?(text)
      rust = self.class.rust_package?(text)
      return unless go || rust

      # an unpack blocked here (pkg_setup needs build deps) still builds under --install, so a
      # human checks the floor on the draft instead of the bump deferring for ever
      unless (work = new_workdir)
        note = 'toolchain floor not checked: the new source could not be unpacked here'
        (c.accepted_diffs ||= []) << note
        Log.log note
        return
      end
      s = source_dir(work)
      plans = []
      plans << go_check(text, work, s) if go
      plans << rust_check(plans.last&.text || text, work, s) if rust
      plans.compact!
      if (esc = plans.find { |p| p.action == :escalate })
        c.evidence.write('toolchain.txt', "#{esc.reason}\n")
        raise Escalate.new(esc.reason, c.evidence.dir)
      end
      changed = plans.select { |p| p.action == :rewrite }
      noted = plans.select { |p| %i[rewrite note].include?(p.action) }
      if noted.empty?
        Log.ok 'toolchain floors unchanged'
        return
      end
      File.write(c.new_ebuild, changed.last.text, encoding: 'UTF-8') unless changed.empty?
      c.accepted_diffs ||= []
      noted.each do |p|
        c.accepted_diffs << p.note
        Log.log p.note
      end
      c.evidence.write('toolchain.txt', noted.map(&:note).join("\n") + "\n")
    end

    private

    def go_check(text, work, s)
      gomod = nearest(work, s, 'go.mod') or return nil
      line, required = self.class.go_directive(gomod)
      return nil unless line
      return Plan.escalate("go.mod has a go directive this engine cannot read: #{line}") unless required
      self.class.go_plan(text, required: required, line: line,
                               eclass_floor: self.class.eclass_go_floor(gentoo_eclass('go-module')) || abort_tree('go-module.eclass floor'),
                               best: best_visible('dev-lang/go') || abort_tree('a visible dev-lang/go'),
                               rewrite: !@c.bundles)
    end

    def rust_check(text, work, s)
      pkg = read(File.join(s, 'Cargo.toml'))
      ws_dir, ws = nearest_dir(work, s, 'Cargo.toml') { |t| t.match?(/^\[workspace\]/) }
      line, required = self.class.cargo_rust_version(pkg, ws)
      eclass_default = self.class.eclass_rust_default(gentoo_eclass('rust')) || abort_tree('rust.eclass slots')
      return member_check(text, ws_dir || s, eclass_default) unless required
      best = [best_visible('dev-lang/rust'), best_visible('dev-lang/rust-bin')].compact.max { |a, b| self.class.compare(a, b) }
      best or abort_tree('a visible dev-lang/rust or rust-bin')
      self.class.rust_plan(text, required: self.class.pad(required), line: line,
                                 eclass_default: eclass_default, best: best, rewrite: !@c.bundles)
    end

    def member_check(text, root, eclass_default)
      return nil unless self.class.inherits?(text, 'cargo')
      members = cargo_members(root).filter_map do |path|
        line, ver = self.class.toml_value(read(path), 'package', 'rust-version')
        [path.delete_prefix("#{root}/"), line, ver] if ver
      end
      if members.empty?
        Log.log 'toolchain floors: no rust-version found'
        return nil
      end
      self.class.member_plan(text, members: members, eclass_default: eclass_default)
    end

    # Member manifests under the workspace root; vendored crates and build output are not members.
    def cargo_members(root)
      out, ok = @c.sh('find', root, '-maxdepth', '3', '(', '-name', 'vendor', '-o', '-name', 'cargo_home',
                      '-o', '-name', 'target', ')', '-prune', '-o', '-name', 'Cargo.toml', '-print', sudo: true)
      ok ? out.lines.map(&:chomp).reject(&:empty?) : []
    end

    def abort_tree(what) = raise(Abort, "toolchain floors: cannot read #{what} from the ::gentoo tree")

    # ArtifactDiff leaves tree-new.txt only when it unpacked the new ebuild in this run; a work
    # dir without it may be a previous run's.
    def new_workdir
      c = @c
      eb = File.basename(c.new_ebuild)
      unless File.exist?(c.evidence.path('tree-new.txt'))
        _, ok = Dir.chdir(c.pkgdir) { c.sh('ebuild', eb, 'clean', 'unpack', sudo: true, timeout: c.cfg.op_timeout) }
        return nil unless ok
      end
      tmpd = `portageq envvar PORTAGE_TMPDIR 2>/dev/null`.strip
      tmpd = '/var/tmp' if tmpd.empty?
      "#{tmpd}/portage/#{c.cat}/#{File.basename(eb, '.ebuild')}/work"
    end

    # S as the ebuild set it, from the saved environment; WORKDIR when it is not there.
    def source_dir(work)
      env = read(File.join(File.dirname(work), 'temp/environment')).to_s
      s = env[/^declare -[-x]* S="(.*)"$/, 1]
      s && read_dir?(s) ? s.chomp('/') : work
    end

    # The file nearest to dir, walking up to the work dir, as go and cargo look for it; with a
    # block, the nearest one the block accepts.
    def nearest(work, dir, name, &accept) = nearest_dir(work, dir, name, &accept)&.last

    # [the directory, the file's text] of that nearest file.
    def nearest_dir(work, dir, name)
      d = dir
      loop do
        t = read(File.join(d, name))
        return [d, t] if t && (!block_given? || yield(t))
        return nil if d == work || !d.start_with?("#{work}/")
        d = File.dirname(d)
      end
    end

    # The work dir belongs to portage, so reads go through sudo like the artifact diff's.
    def read(path)
      out, ok = @c.sh('cat', path, sudo: true)
      ok ? out : nil
    end

    def read_dir?(path) = @c.sh('test', '-d', path, sudo: true)[1]

    def gentoo_eclass(name)
      repo = `portageq get_repo_path / gentoo 2>/dev/null`.strip
      return nil if repo.empty?
      File.read(File.join(repo, 'eclass', "#{name}.eclass"))
    rescue SystemCallError
      nil
    end

    def best_visible(atom)
      out = `portageq best_visible / #{atom} 2>/dev/null`.strip
      out[%r{\A#{Regexp.escape(atom)}-(\d.*?)(?:-r\d+)?\z}, 1]
    end
  end
end
