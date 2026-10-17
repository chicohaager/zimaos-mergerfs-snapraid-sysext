#!/bin/sh
# Version pins: every place that pins a version must agree (FAIL), and a newer
# upstream release / commit is reported (WARN, never fails — bump deliberately).
# Usage: sh tests/check-versions.sh        (uses GITHUB_TOKEN if set, for the API)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
FAILS=0
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
warn() {
    echo "WARN - $1"
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning title=version pin::$1"
    return 0
}

# --- the pins -------------------------------------------------------------------
mf_ci="$(sed -n 's/^ *MERGERFS_VERSION: *"\(.*\)"$/\1/p' .github/workflows/build.yml)"
sr_ci="$(sed -n 's/^ *SNAPRAID_VERSION: *"\(.*\)"$/\1/p' .github/workflows/build.yml)"
mf_sx="$(sed -n 's/^MERGERFS_VERSION="\${MERGERFS_VERSION:-\(.*\)}"$/\1/p' build/build-sysext.sh)"
sr_bs="$(sed -n 's/^SNAPRAID_VERSION="\${SNAPRAID_VERSION:-\(.*\)}"$/\1/p' build/build-snapraid.sh)"
sr_df="$(sed -n 's/^ARG SNAPRAID_VERSION=\(.*\)$/\1/p' build/Dockerfile.snapraid)"
mft="$(sed -n 's/^ARG MFT_SHA=\([0-9a-f]*\)$/\1/p' build/Dockerfile.mergerfs-tools)"
echo "pins: mergerfs ci=$mf_ci sysext=$mf_sx | snapraid ci=$sr_ci build=$sr_bs dockerfile=$sr_df | mergerfs-tools=$mft"

for v in "$mf_ci" "$sr_ci" "$mf_sx" "$sr_bs" "$sr_df" "$mft"; do
    [ -n "$v" ] || fail "a pin could not be read (empty) — did a file's format change?"
done
[ "$mf_ci" = "$mf_sx" ] || fail "mergerfs: build.yml $mf_ci != build-sysext.sh $mf_sx"
[ "$sr_ci" = "$sr_bs" ] || fail "snapraid: build.yml $sr_ci != build-snapraid.sh $sr_bs"
[ "$sr_ci" = "$sr_df" ] || fail "snapraid: build.yml $sr_ci != Dockerfile.snapraid $sr_df"
for a in amd64 arm64; do
    grep -q "^    ${mf_ci}-${a}) MERGERFS_SHA256=[0-9a-f]\{64\} ;;" build/build-sysext.sh \
        || fail "build-sysext.sh has no pinned SHA256 for mergerfs ${mf_ci}/${a}"
done
# docs that state the pins
grep -q "mergerfs ${mf_ci} .*SnapRAID ${sr_ci}" .github/workflows/build.yml \
    || fail "build.yml header comment does not name mergerfs ${mf_ci} / SnapRAID ${sr_ci}"
grep -q "mergerfs \`${mf_ci}\`.*\`${sr_ci}\`" README.md \
    || fail "README 'Version pins' row does not name ${mf_ci} / ${sr_ci}"
grep -q "mergerfs (v${mf_ci}), snapraid (v${sr_ci}" docs/HANDOFF.md \
    || fail "docs/HANDOFF.md does not name v${mf_ci} / v${sr_ci}"

# --- upstream (informational) -----------------------------------------------------
api() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/$1"
    else
        curl -fsS "https://api.github.com/$1"
    fi
}
latest() { api "repos/$1/releases/latest" 2>/dev/null | sed -n 's/^  "tag_name": "v\{0,1\}\(.*\)",$/\1/p'; }
mf_up="$(latest trapexit/mergerfs)"
sr_up="$(latest amadvance/snapraid)"
mft_up="$(api repos/trapexit/mergerfs-tools/commits/master 2>/dev/null | sed -n 's/^  "sha": "\([0-9a-f]*\)",$/\1/p' | head -1)"
if [ -z "$mf_up" ] || [ -z "$sr_up" ] || [ -z "$mft_up" ]; then
    warn "upstream check incomplete (GitHub API unreachable or rate-limited): mergerfs='$mf_up' snapraid='$sr_up' mergerfs-tools='$mft_up' — NOT checked"
fi
[ -n "$mf_up" ] && [ "$mf_up" != "$mf_ci" ] && warn "mergerfs $mf_up is released, pinned $mf_ci"
[ -n "$sr_up" ] && [ "$sr_up" != "$sr_ci" ] && warn "SnapRAID $sr_up is released, pinned $sr_ci"
[ -n "$mft_up" ] && [ "$mft_up" != "$mft" ] && warn "mergerfs-tools master is ${mft_up%"${mft_up#????????????}"}, pinned ${mft%"${mft#????????????}"} (check the upstream changes before bumping)"
echo "upstream: mergerfs=${mf_up:-?} snapraid=${sr_up:-?} mergerfs-tools=${mft_up:-?}"

if [ "$FAILS" = 0 ]; then echo "pins consistent"; else echo "$FAILS pin check(s) FAILED"; fi
[ "$FAILS" = 0 ]
