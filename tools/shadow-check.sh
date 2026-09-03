#!/usr/bin/env bash
# Dry-run the engine over the live nvchecker bump queue. For each open [nvchecker] issue:
# resolve it to (pkg, ver), run `--check`, and classify the call (would-bump / escalate /
# defer). Non-destructive: --check makes no repo writes and no build. It proves the engine
# runs against real issues on CI and shows which of them are mechanical bump candidates.
#
#   AUTOBUMP_REPO=/path/to/overlay tools/shadow-check.sh            # whole open queue
#   AUTOBUMP_REPO=/path/to/overlay tools/shadow-check.sh 11000 ...  # explicit issues
#
# Env: UPSTREAM (default gentoo-zh/overlay), AUTOBUMP_REPO (the overlay checkout).
set -uo pipefail
SELFDIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$SELFDIR/.."
ENGINE="$ROOT/bin/autobump"
UPSTREAM="${UPSTREAM:-gentoo-zh/overlay}"

label() { case "$1" in
    0) echo "would-bump (mechanical)" ;; 2) echo "defer/precondition" ;;
    3) echo "ESCALATE (needs judge)" ;; *) echo "exit$1" ;; esac; }

if [ $# -gt 0 ]; then issues=("$@")
else mapfile -t issues < <(gh issue list --repo "$UPSTREAM" --state open --limit 100 \
        --json number,title --jq '.[] | select(.title|startswith("[nvchecker]")) | .number'); fi

mech=0; esc=0; defer=0
for n in "${issues[@]}"; do
    title=$(gh issue view "$n" --repo "$UPSTREAM" --json title --jq .title 2>/dev/null)
    pkg=$(sed -nE 's/^\[nvchecker\] ([a-z0-9-]+\/[A-Za-z0-9_+-]+) can be bump to .*/\1/p' <<<"$title")
    ver=$(sed -nE 's/.* can be bump to ([A-Za-z0-9._+-]+)$/\1/p' <<<"$title")
    if [ -z "$pkg" ] || [ -z "$ver" ]; then printf 'SKIP #%-6s (unparsable title)\n' "$n"; continue; fi
    # the sweep passes the overlay's per-package flags (retention, variable rewrite); without
    # them a package that needs a rewrite is counted as an escalation the sweep never sees
    args=()
    if [ -n "${AUTOBUMP_REPO:-}" ] && [ -x "$AUTOBUMP_REPO/scripts/autobump-args.py" ]; then
        mapfile -t args < <(cd "$AUTOBUMP_REPO" && python3 scripts/autobump-args.py "$pkg" 2>/dev/null)
    fi
    ruby "$ENGINE" "$pkg" "$ver" --check "${args[@]}" >/dev/null 2>&1; rc=$?
    case "$rc" in 0) mech=$((mech+1));; 3) esc=$((esc+1));; 2) defer=$((defer+1));; esac
    printf '#%-6s %-34s %-14s %s\n' "$n" "$pkg" "$ver" "$(label "$rc")"
done
echo "----"
echo "shadow: ${#issues[@]} issues | mechanical ${mech}, escalate ${esc}, defer ${defer}"
