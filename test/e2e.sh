#!/usr/bin/env bash
# Hermetic end-to-end test of the FULL autobump-rb pipeline (stages 3-7) against
# real portage: branch -> fetch -> manifest -> artifact diff -> emerge -> elog
# gate -> smoke -> pkgcheck delta -> commit. Unlike test/decisions.sh (classify
# core only, no writes), this actually emerges a package and asserts a correct,
# clean commit -- the last gate before the build/commit stages are trusted for a
# real bump. It is the reproducible CI proof of those stages.
#
# Hermetic: a throwaway git overlay + a trivial fixture package (demo-e2e/hello)
# whose distfile is generated here and served from 127.0.0.1:8199, so there is
# no network, no upstream version drift, and nothing to clean off a real system
# except unmerging one trivial package (done in the EXIT trap).
#
# Requires: ROOT (emerge writes to the live vdb), portage with a gentoo repo,
# and: ruby git curl python3 pkgdev pkgcheck qlist emerge.
#
#   sudo bash test/e2e.sh              # run it
#   sudo AB_KEEP=1 bash test/e2e.sh    # keep the workdir for inspection
#
# Exit 0 = the engine produced a correct clean commit AND merged+smoked the pkg.
set -uo pipefail

SELFDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELFDIR/.." && pwd)"
PORT=8199
REPO_NAME="abe2e"
PKG="demo-e2e/hello"
OLDVER="1.0.0"
NEWVER="1.0.1"

fail() { echo "E2E FAIL: $*" >&2; exit 1; }
note() { echo ">> $*"; }

[ "$(id -u)" = 0 ] || fail "must run as root (emerge writes to the live vdb)"
for t in ruby git curl python3 pkgdev pkgcheck qlist emerge ebuild portageq; do
    command -v "$t" >/dev/null 2>&1 || fail "missing required tool: $t"
done

# a gentoo repo must exist to be the master of the fixture overlay
GENTOO_REPO="$(portageq get_repo_path / gentoo 2>/dev/null)"
[ -n "$GENTOO_REPO" ] && [ -d "$GENTOO_REPO" ] || fail "no ::gentoo repo (run emerge-webrsync first)"

WORK="$(mktemp -d /tmp/autobump-e2e-XXXXXX)"
OVL="$WORK/overlay"
DISTDIR="$WORK/distfiles"
REPOCONF="/etc/portage/repos.conf/${REPO_NAME}-e2e.conf"
KWFILE="/etc/portage/package.accept_keywords/autobump-hello"
SERVER_PID=""

cleanup() {
    local rc=$?
    note "cleanup"
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    # unmerge the fixture package if the engine merged it (keep the system clean)
    if qlist -Iqe "$PKG" >/dev/null 2>&1; then
        emerge --quiet --unmerge ">=${PKG}-0" >/dev/null 2>&1 || true
    fi
    rm -f "$REPOCONF" "$KWFILE"
    [ -n "${AB_KEEP:-}" ] || rm -rf "$WORK"
    [ -n "${AB_KEEP:-}" ] && note "kept workdir: $WORK"
    return $rc
}
trap cleanup EXIT

# ---- 1. build the throwaway overlay from the checked-in fixture package -------
note "overlay at $OVL (master = $GENTOO_REPO)"
mkdir -p "$OVL/metadata" "$OVL/profiles" "$OVL/$PKG" "$DISTDIR"
echo "masters = gentoo" > "$OVL/metadata/layout.conf"
echo "$REPO_NAME" > "$OVL/profiles/repo_name"
echo "demo-e2e" > "$OVL/profiles/categories"   # portage must know the fixture category
cp "$SELFDIR/fixtures/demo-e2e/hello/hello-${OLDVER}.ebuild" "$OVL/$PKG/"
cp "$SELFDIR/fixtures/demo-e2e/hello/metadata.xml" "$OVL/$PKG/"

# ---- 2. generate the fixture distfiles (old + new), served locally -----------
mkftar() { # $1 = version
    local v="$1" d="$WORK/src/hello-$1"
    mkdir -p "$d"
    printf '#!/bin/sh\necho "hello version %s"\n' "$v" > "$d/hello"
    chmod +x "$d/hello"
    tar czf "$DISTDIR/hello-${v}.tar.gz" -C "$WORK/src" "hello-$v"
}
mkftar "$OLDVER"
mkftar "$NEWVER"
python3 -m http.server "$PORT" --directory "$DISTDIR" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1
curl -sf "http://127.0.0.1:${PORT}/hello-${NEWVER}.tar.gz" -o /dev/null || fail "local distfile server not answering"

# ---- 3. register the overlay + accept ~amd64, so emerge can build it ----------
mkdir -p /etc/portage/repos.conf /etc/portage/package.accept_keywords
# pkgcore (pkgdev/pkgcheck) reads /etc/portage/repos.conf/ but NOT portage's built-in
# /usr/share/portage/config/repos.conf, so on a plain stage3 it cannot see the 'gentoo'
# repo that emerge uses -> `pkgdev manifest` aborts ("default repo 'gentoo' is undefined").
# Declare gentoo (+ main-repo) explicitly here if the checkout doesn't already.
grep -rqs '^\[gentoo\]' /etc/portage/repos.conf/ 2>/dev/null || cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = $GENTOO_REPO
EOF
cat > "$REPOCONF" <<EOF
[$REPO_NAME]
location = $OVL
masters = gentoo
priority = 50
EOF

# ---- 4. manifest the base version + commit master (clean tree for preflight) -
export DISTDIR              # portage (ebuild/emerge) fetches+builds from here
# portage drops to the 'portage' user for ebuild phases; mktemp -d is 0700, so
# make the whole workdir world-readable/traversable or sourcing the ebuild fails.
chmod -R a+rX "$WORK"
mout="$( cd "$OVL/$PKG" && ebuild "hello-${OLDVER}.ebuild" manifest 2>&1 )" \
    || fail "base manifest failed: $mout"
git -C "$OVL" init -q -b master
git -C "$OVL" config user.name  "e2e"
git -C "$OVL" config user.email "e2e@example.invalid"
git -C "$OVL" add -A
git -C "$OVL" commit -q -m "init e2e overlay"
git -C "$OVL" remote add self "$OVL"          # preflight syncs master from here
git -C "$OVL" fetch -q self

# ---- 5. RUN THE ENGINE, full pipeline, real emerge ---------------------------
note "running: ruby bin/autobump $PKG $NEWVER --install"
set +e
env AUTOBUMP_REPO="$OVL" \
    AUTOBUMP_LIVE_OVERLAY="$OVL" \
    AUTOBUMP_SYNC_REMOTE="self" \
    AUTOBUMP_UPSTREAM_REPO="demo/e2e" \
    AUTOBUMP_DISTDIR="$DISTDIR" \
    AUTOBUMP_BOT_NAME="gentoo-zh autobump" \
    AUTOBUMP_BOT_EMAIL="bot@gentoozh.org" \
    DISTDIR="$DISTDIR" \
    ruby "$ROOT/bin/autobump" "$PKG" "$NEWVER" --install
ENGINE_RC=$?
set -e

# ---- 6. assert ---------------------------------------------------------------
note "engine exit=$ENGINE_RC; asserting"
if [ "$ENGINE_RC" != 0 ]; then
    echo "--- DIAG repos.conf ---";  cat /etc/portage/repos.conf/*.conf 2>/dev/null
    echo "--- DIAG pkgdev version ---"; pkgdev --version 2>&1
    echo "--- DIAG manual pkgdev manifest ---"; ( cd "$OVL/$PKG" && pkgdev manifest 2>&1 )
    fail "engine exit $ENGINE_RC (expected 0)"
fi

BRANCH="demo-e2e-hello-${NEWVER}"
git -C "$OVL" rev-parse --verify -q "$BRANCH" >/dev/null || fail "branch $BRANCH not created"
subj="$(git -C "$OVL" log -1 --format=%s "$BRANCH")"
echo "$subj" | grep -q "$PKG" || fail "commit subject does not mention $PKG: $subj"
git -C "$OVL" show "$BRANCH:$PKG/hello-${NEWVER}.ebuild" >/dev/null 2>&1 \
    || fail "new ebuild not committed"
git -C "$OVL" show "$BRANCH:$PKG/hello-${OLDVER}.ebuild" >/dev/null 2>&1 \
    && fail "old ebuild still present (should be dropped)"
# manifest must reference the new distfile
git -C "$OVL" show "$BRANCH:$PKG/Manifest" 2>/dev/null | grep -q "hello-${NEWVER}.tar.gz" \
    || fail "Manifest missing new distfile"
# really merged + smoke
qlist -Iqe "$PKG" >/dev/null 2>&1 || fail "$PKG not merged into vdb"
hello_out="$(hello --version 2>&1 || true)"
echo "$hello_out" | grep -q "$NEWVER" || fail "smoke: 'hello' did not report $NEWVER (got: $hello_out)"

# ---- 7. a distfile the server does not have must escalate, not defer ---------
# The local server has no hello-${MISSINGVER}.tar.gz, so stage 4 gets a 404. That is
# permanent: retrying it every sweep would only refile "will retry automatically" and
# hide the real defect. Assert exit 3 (escalate), not 2 (transient defer).
MISSINGVER="1.0.2"
note "running: ruby bin/autobump $PKG $MISSINGVER --install (distfile absent, expect escalate)"
set +e
miss_out="$(env AUTOBUMP_REPO="$OVL" \
    AUTOBUMP_LIVE_OVERLAY="$OVL" \
    AUTOBUMP_SYNC_REMOTE="self" \
    AUTOBUMP_UPSTREAM_REPO="demo/e2e" \
    AUTOBUMP_DISTDIR="$DISTDIR" \
    AUTOBUMP_BOT_NAME="gentoo-zh autobump" \
    AUTOBUMP_BOT_EMAIL="bot@gentoozh.org" \
    DISTDIR="$DISTDIR" \
    ruby "$ROOT/bin/autobump" "$PKG" "$MISSINGVER" --install 2>&1)"
MISS_RC=$?
set -e
[ "$MISS_RC" = 3 ] || { printf '%s\n' "$miss_out" | tail -20; fail "missing distfile: exit $MISS_RC (expected 3, escalate)"; }
printf '%s' "$miss_out" | grep -q "is missing (404/403)" \
    || { printf '%s\n' "$miss_out" | tail -20; fail "missing distfile: escalation did not name the 404"; }

echo
echo "E2E PASS: engine bumped $PKG $OLDVER -> $NEWVER"
echo "  commit : $subj"
echo "  merged : $(qlist -Iqe "$PKG"); smoke: $hello_out"
echo "  404    : $PKG $MISSINGVER escalated (exit 3), not deferred"
exit 0
