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

# --- GitHub Actions: full-SHA pins with the tag as comment --------------------------
# Format: `uses: owner/repo@<40-hex sha> # vX.Y.Z`. A moving tag (@v4) can change
# under a released workflow; the comment keeps it readable and lets this check
# confirm the SHA really is that tag and report newer releases.
uses_lines="$(grep -E '^[[:space:]]*(- )?uses:' .github/workflows/*.yml)"
[ -n "$uses_lines" ] || fail "no 'uses:' lines found in .github/workflows — parser out of date?"
n_actions=0
for spec in $(printf '%s\n' "$uses_lines" \
        | sed -n 's/.*uses: *\([^ @]*\)@\([^ ]*\)\( *# *\(v[0-9][0-9.]*\)\)\{0,1\}.*/\1@\2@\4/p' | sort -u); do
    n_actions=$((n_actions + 1))
    act="${spec%%@*}"; rest="${spec#*@}"; ref="${rest%%@*}"; tag="${rest#*@}"
    case "$ref" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
        *) fail "$act@$ref is not pinned to a commit SHA"; continue ;;
    esac
    [ "${#ref}" = 40 ] || { fail "$act@$ref: SHA is not 40 characters"; continue; }
    [ -n "$tag" ] || { fail "$act@$ref has no '# vX.Y.Z' tag comment"; continue; }
    tag_sha="$(api "repos/$act/commits/$tag" 2>/dev/null | sed -n 's/^  "sha": "\([0-9a-f]*\)",$/\1/p' | head -1)"
    if [ -z "$tag_sha" ]; then
        warn "$act: tag $tag NOT checked against the pinned SHA (API unreachable)"
    elif [ "$tag_sha" != "$ref" ]; then
        fail "$act: pinned $ref but tag $tag is $tag_sha"
    fi
    up="$(api "repos/$act/releases/latest" 2>/dev/null | sed -n 's/^  "tag_name": "\(.*\)",$/\1/p')"
    [ -n "$up" ] && [ "$up" != "$tag" ] && warn "$act $up is released, pinned $tag"
done
echo "actions checked: $n_actions"
# actionlint is downloaded by version + SHA256 (Dependabot does not see it)
al_pin="$(sed -n 's/^ *ACTIONLINT_VERSION: *"\(.*\)"$/\1/p' .github/workflows/build.yml)"
if [ -z "$al_pin" ]; then
    fail "ACTIONLINT_VERSION not found in build.yml"
else
    grep -q "ACTIONLINT_SHA256: *\"[0-9a-f]\{64\}\"" .github/workflows/build.yml \
        || fail "ACTIONLINT_SHA256 missing or not 64 hex characters"
    al_up="$(latest rhysd/actionlint)"
    [ -n "$al_up" ] && [ "$al_up" != "$al_pin" ] && warn "actionlint $al_up is released, pinned $al_pin (update version AND SHA256)"
    echo "actionlint: pinned=$al_pin upstream=${al_up:-?}"
fi
# Dependabot keeps the SHA pins moving (it updates the SHA and the "# vX.Y.Z" comment);
# without it the pins went up to four majors stale and only this log warned.
grep -q 'package-ecosystem: *"\{0,1\}github-actions' .github/dependabot.yml 2>/dev/null \
    || fail ".github/dependabot.yml does not update github-actions"
[ "$n_actions" -gt 0 ] || fail "parsed 0 actions from $(printf '%s\n' "$uses_lines" | wc -l) uses: lines"

if [ "$FAILS" = 0 ]; then echo "pins consistent"; else echo "$FAILS pin check(s) FAILED"; fi
[ "$FAILS" = 0 ]
