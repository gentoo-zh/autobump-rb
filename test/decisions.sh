#!/usr/bin/env bash
# Golden decision test: run the classifier (`--check`) on every fixture bump and assert the
# call it makes. A "decision" is (exit code, escalation notes). The expected value for each
# fixture is frozen in test/decisions.tsv, so any change in classification shows up as a
# regression -- there is no second implementation to diff against, the table IS the spec.
#
# Hermetic: runs against test/fixtures, a self-contained overlay that exercises every
# classify branch (mechanical, major-jump, prerelease, source-pin, comment/inline pin,
# applied-patches, multi-arch, deps-artifact 404, date version, downgrade, haskell-cabal).
# Needs only ruby, git and curl (the deps-artifact row probes a URL).
#
#   bash test/decisions.sh                 # fixtures + test/decisions.tsv
#   AUTOBUMP_REPO=/path/to/overlay bash test/decisions.sh my-table.tsv   # a real overlay
set -uo pipefail
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
export AUTOBUMP_REPO="${AUTOBUMP_REPO:-$SELFDIR/fixtures}"
ENGINE="$SELFDIR/../bin/autobump"
TABLE="${1:-$SELFDIR/decisions.tsv}"

pass=0 fail=0
while IFS=$'\t' read -r pkg ver want_exit want_notes; do
    [ -n "$pkg" ] || continue
    case "$pkg" in \#*) continue ;; esac
    out=$(ruby "$ENGINE" "$pkg" "$ver" --check 2>&1); rc=$?

    err=""
    [ "$rc" = "$want_exit" ] || err="exit $rc, want $want_exit"
    if [ "$want_exit" = 0 ]; then
        grep -q '^ESCALATE:' <<<"$out" && err="${err:+$err; }mechanical case but engine escalated"
    else
        # every "||"-joined phrase must appear in the escalation output
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            grep -qF "$p" <<<"$out" || err="${err:+$err; }missing note: $p"
        done < <(printf '%s\n' "$want_notes" | sed 's/||/\n/g')
    fi

    if [ -z "$err" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        printf 'FAIL  %-28s %-12s  %s\n' "$pkg" "$ver" "$err"
        grep '^ESCALATE:' <<<"$out" | sed 's/^/        /'
    fi
done < "$TABLE"
echo "----"
echo "decisions: $pass passed, $fail failed"
# an empty or missing table would otherwise report a clean run over nothing
[ "$pass" -gt 0 ] || { echo "decisions: the table produced no cases ($TABLE)" >&2; exit 1; }
[ "$fail" -eq 0 ]
