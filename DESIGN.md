# autobump-rb — design

Modular engine for mechanical Gentoo overlay version bumps: do the deterministic bump, or `exit 3`
with an evidence pack when it isn't mechanical. Runs on gentoo-zh CI over the nvchecker queue. It only
does bumps it can prove safe; anything needing judgement escalates. No LLM in this path.

## Division of labour

- **Engine** — deterministic ops; `exit 3` + evidence when not mechanical.
- **Judge (optional, downstream)** — reads the `exit 3` evidence pack, or authors a fix. With none
  configured, every escalation just reaches a human.
- **`gentoo-replay-eval`** — replays real historical bumps to check the mechanical/escalate call
  against ground truth.
- **Generality gate** — a recurring fix becomes a built-in signal only once it is shown to be general.

The op-registry deepening and richer GUI-package handling live in a sibling repo,
**[autobump-gui](https://github.com/gentoo-zh/autobump-gui)**; this stays the small mechanical core.

## Pipeline

`cli.rb` parses args (resolving an nvchecker issue if given), then runs the stages. One module each:

| stage | module | responsibility |
|---|---|---|
| args + issue resolve | `cli.rb`, `issue.rb` | parse args / turn an issue into (pkg, newver) |
| 1 locate | `locate.rb` | find the current release ebuild, derive versions (skip 9999 ebuilds) |
| 2 classify | `classify.rb` | the safety gate — escalate on any non-mechanical signal |
| env / remotes | `config.rb` | env-driven config; canonical sync remote |
| runtime | `runtime.rb` | Context, `sh` helper, Abort/Escalate, exit codes |
| evidence pack | `evidence.rb` | the `exit 3` evidence directory |
| 3 preflight | `preflight.rb`, `cleanup.rb` | clean-tree gate, sync master, branch, baseline pkgcheck |
| 4 distfiles | `distfiles.rb` | write the new ebuild, fetch, regenerate Manifest |
| 5 artifact diff | `artifact_diff.rb` | payload file-tree diff / source build-surface diff |
| 6 build test | `build_test.rb` | emerge with CI's elog config, gate, smoke, GUI probe, qa-vdb |
| 7 finalize | `finalize.rb` | drop old ebuild (per-package `keep_old = N` keeps the N most-recent instead), pkgcheck delta, commit as the bot |
| 8 PR | `pr.rb` | push, open a PR, cc maintainers, draft multi-arch bumps |

`--check` stops after classify (no writes, no remotes); `--diff-only` after stage 5; `--install` runs
the build test and finalize (a local commit) but stops before push/PR; `--pr` runs all. With per-package
`keep_old = N`, stage 7 keeps the N most-recent versions instead of dropping the replaced one (adds the
new ebuild, drops anything older; `0` keeps all), and `pkgdev manifest` keeps the DIST of whatever remains.

## Classification signals (stage 2)

Each is a way a plain copy-and-refetch would ship something wrong, so it escalates with a note:

- **major_jump** — major component changed, or a date version went backwards. Major bumps routinely
  move deps/USE.
- **prerelease** — target is alpha/beta/rc/pre/nightly and there is no existing prerelease ebuild to
  pattern off.
- **not_newer** — target does not sort strictly newer. A downgrade still fetches/builds against the
  older source, so nothing downstream catches it.
- **source_pin** — ebuild pins a `_COMMIT`/`_TAG` with no per-version vendor bundle; a version-only
  copy keeps the stale pin while distfiles + emerge succeed against the old source.
- **deps_artifact** — the new version's `-vendor`/`-crates`/`-deps`/`node_modules` bundle URL 404s.
- **applied_patches** — the ebuild applies `files/*.patch`; re-application needs a human.
- **hackport_cabal** — a `haskell-cabal` ebuild: dep bounds / ghc floors / hackage revision come from
  the upstream `.cabal`, not the ebuild, so a version-only copy keeps stale bounds.

A pin that is only *recorded* (a byte-identical `GIT_CRATES`/`_VER=` line) does not escalate — a stale
one surfaces downstream as a 404 or build failure. Every signal is pinned by a fixture in the golden
test.

## Testing

- **Golden decision test** (`test/decisions.sh`) — classifier over `test/fixtures` (every branch
  above), each call asserted against the frozen `test/decisions.tsv`. Hermetic: ruby, git, curl. The
  table is the spec, so a classification change shows up as a diff.
- **End-to-end** (`test/e2e.sh`) — really emerges a throwaway fixture through the full pipeline in a
  gentoo container and asserts a clean commit, then unmerges. Runs in CI (`e2e.yml`).
- **Live dry-run** (`tools/shadow-check.sh`, `selftest.yml`) — `--check` over the real open queue,
  reports the mechanical/escalate/defer breakdown.

## Deploy (gentoo-zh)

`autobump.yml` clones this repo, installs `dev-lang/ruby`, and runs the daily sweep over the nvchecker
queue with no model, so non-mechanical bumps get an evidence comment and stop and a human merges every
PR. `autobump-trial.yml` (workflow_dispatch, `targets` = nvchecker issue numbers) sets up the same
container but calls the engine with `--install` per target — a real build test + install of a candidate
that is not opted in, without opening a PR — to prove it bumps mechanically before a maintainer adds
`autobump = true`. Container-only gotchas a dev box never hits: a literal `$(nproc)` in `make.conf` breaks portage's
parser (expand it in the workflow); `pkgdev`/`pkgcheck`/`github-cli` are under `dev-util/`; pkgcore
needs an explicit gentoo `repos.conf` or `pkgdev manifest` fails with "gentoo undefined"; and a
`package.use/ci-binhost` must align heavy-dep USE to the binhost's binpkgs (webkit-gtk `+keyring`,
qtwebengine `+bindist`) or they fail the USE match and rebuild from source, blowing the op-timeout —
kept in sync with `emerge-on-pr.yml`. Ops runbook (App, secrets, state cache): `docs/deploy.zh-cn.md`.

## Notes

- `hackport_cabal`, `not_newer` and `source_pin` came from `gentoo-replay-eval` catching real misses
  (the static checks escalated 0/12 metadata-driven bumps; adding haskell-cabal took recall to 92%).
- Ruby because the stages shell out to coreutils / portage / git — the language is glue, not where the
  logic lives. GPL-2.
