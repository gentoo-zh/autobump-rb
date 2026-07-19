# autobump-rb

[繁體中文](README.zh-tw.md)

A deterministic engine for the **mechanical** part of maintaining a Gentoo overlay: given a package
and a new upstream version it either lands a clean bump — copy the ebuild, refetch, regenerate the
Manifest, build-test, run the QA gates, commit, open a PR — or stops with an **evidence pack** saying
why the bump is not mechanically safe.

A per-package `keep_old = N` instead keeps the N most-recent versions on a bump (add the new ebuild,
drop anything older; `0` keeps them all), for packages that intentionally retain several versions.

It only does bumps it can prove safe. Anything needing judgement — a new dependency, a major-version
jump, a stale source pin, a changed build surface — escalates instead of being patched from a guess.
No LLM in the mechanical path.

## Exit-code contract

Everything downstream (the sweep driver, CI, a judge) keys off three exit codes:

| code | meaning | who acts |
|---|---|---|
| **0** | mechanical bump done (or, with `--check`, *would* be done) | nobody — merge the PR |
| **2** | transient defer: precondition failed, fetch flake, build timeout, dep-resolution gap | retry next run |
| **3** | escalate: not mechanically safe, evidence pack written | a judge or a human |

## Usage

    ruby bin/autobump <cat/pkg> <newver> --check      # classify only: mechanical (0) or escalate (3)
    ruby bin/autobump <issue#> --check                # resolve an nvchecker bump issue first
    ruby bin/autobump <cat/pkg> <newver> --pr         # full pipeline: build-test, commit, open PR
    ruby bin/autobump <cat/pkg> <newver> --install    # local build-test: build+install+pkgcheck, local commit, no push/PR

    rake                                              # syntax + the golden decision test (what CI runs)
    bash test/decisions.sh                            # golden decision test on its own (hermetic fixtures)
    sudo bash test/e2e.sh                             # hermetic end-to-end: really emerges a fixture pkg

`--install` without `--pr` is a local build-test — it runs the full pipeline through the local commit
but pushes nothing; overlay's `autobump-trial.yml` uses it to build-test candidates not yet opted in.

Not tied to gentoo-zh: `AUTOBUMP_REPO` (any overlay checkout) and `AUTOBUMP_UPSTREAM_REPO` (any
GitHub repo) are env-driven, and the defaults work both on a dev box (fork clone + sudo) and in CI
(root, canonical checkout).

## How it is tested

- **Golden decision test** (`test/decisions.sh`, hermetic, in CI) — the classifier over
  `test/fixtures` (every classify branch), each call asserted against the frozen `test/decisions.tsv`.
- **End-to-end** (`test/e2e.sh`, gentoo container in CI) — really emerges a throwaway fixture through
  the full pipeline and asserts a clean commit.

Design notes in [`DESIGN.md`](DESIGN.md). GPL-2.
