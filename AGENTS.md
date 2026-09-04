# Repository Guidelines

The engine behind gentoo-zh/overlay's autobump: given a package and a version it either lands a
mechanical bump or stops with an evidence pack.

**Follow gentoo-zh/overlay's `AGENTS.md`.** Its Git workflow, code style, writing, and commit and PR
rules govern this repository too; nothing below repeats them. What follows is what the overlay's
rules do not cover, because this repository holds no ebuilds.

## What must not change quietly

- The exit codes are a contract with the overlay's driver: `0` bumped, `2` defer and retry later,
  `3` escalate to a human. A stage that changes which one it raises changes what the driver records.
- Every escalation writes its evidence into the evidence directory. A new judgement adds the file a
  reviewer needs to check it.
- No model is consulted in the default path. `AUTOBUMP_JUDGE` is opt-in and must stay so.

## Judgements

- A gate exists to catch one thing. Widening it to make one package pass is how it stops catching
  that thing: say in the commit what the wider rule could now hide, and keep the rule as narrow as
  the evidence.
- Reproduce before you change. A claim about a package is worth what its command output shows; a
  claim from reading the code is worth nothing. Real evidence lives in the overlay's run artifacts
  (`gh run download <id> --repo gentoo-zh/overlay --pattern 'autobump-evidence-*'`).
- A payload fold must pair, not sweep: fold a removal only against the addition that replaces it,
  and leave a removal nothing replaces structural.

## Tests

- The overlay is a package repository and carries no test suite. The tests for its autobump driver
  live here, in `test/sweep`, and run against a checkout named by `AUTOBUMP_OVERLAY`.
- `rake` is the suite and what CI runs; `AUTOBUMP_OVERLAY=/path/to/overlay rake` adds `test/sweep`,
  which is skipped without one.
- Every test is hermetic: no portage, no network, no sudo, no git outside a temp directory.
- A behaviour change lands with a test that fails without it. Prove that: break the change in a
  copy, run the test, and see it fail. A test that passes either way pins nothing.
- Pin a decision as a pure method rather than testing around it. `own_elog?`, `upstream_missing?`,
  `retire` and `fold_benign` have that shape because a decision buried in a stage has no test.

## Commits

- `pkgdev commit` is for ebuilds; here use `git commit --signoff`. Everything else - one clean
  commit per logical change, a low commit count grouped by subsystem, the subject and body rules -
  is the overlay's.
- The subject names the file or subsystem: `distfiles: judge a fetch failure per URI`.
