#!/bin/sh
# Check a built sysext image against what ZimaOS and the units need.
# Usage: sh tests/check-raw.sh build/out/mergerfs-snapraid_<arch>.raw
set -u
RAW="${1:?usage: check-raw.sh <image.raw>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME=mergerfs-snapraid
FAILS=0
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }

# ZimaOS kernel: squashfs gzip/lz4/lzo only (KB §18.3)
comp="$(unsquashfs -s "$RAW" | sed -n 's/^Compression //p')"
[ "$comp" = gzip ] || fail "compression is '$comp', ZimaOS needs gzip"

LIST="$(unsquashfs -lls "$RAW")"
# zpkg/systemd-sysext: release file name must match the installed image name (KB §18.9)
printf '%s\n' "$LIST" | grep -q " squashfs-root/usr/lib/extension-release.d/extension-release.${NAME}\$" \
    || fail "extension-release.${NAME} missing"
for b in usr/bin/mergerfs usr/bin/snapraid; do
    printf '%s\n' "$LIST" | grep -q "^-rwx.* squashfs-root/${b}\$" || fail "$b missing or not executable"
done
# every script the units exec must be in the image, executable, and identical to the repo
X="$(mktemp -d)"; trap 'rm -rf "$X"' EXIT
unsquashfs -q -d "$X/r" "$RAW" "usr/lib/${NAME}" >/dev/null 2>&1
for s in "$REPO"/scripts/*.sh; do
    f="$X/r/usr/lib/${NAME}/$(basename "$s")"
    if [ ! -x "$f" ]; then fail "usr/lib/${NAME}/$(basename "$s") missing or not executable"
    elif ! cmp -s "$s" "$f"; then fail "usr/lib/${NAME}/$(basename "$s") differs from scripts/"
    fi
done

for e in "$REPO"/config/*.example; do
    f="$X/r/usr/lib/${NAME}/$(basename "$e")"
    cmp -s "$e" "$f" || fail "usr/lib/${NAME}/$(basename "$e") missing or differs from config/"
done

# VERSIONS must match the pins the build was meant to use
V="$X/r/usr/lib/${NAME}/VERSIONS"
mf_pin="$(sed -n 's/^ *MERGERFS_VERSION: *"\(.*\)"$/\1/p' "$REPO/.github/workflows/build.yml")"
sr_pin="$(sed -n 's/^ *SNAPRAID_VERSION: *"\(.*\)"$/\1/p' "$REPO/.github/workflows/build.yml")"
grep -qx "MERGERFS_VERSION=$mf_pin" "$V" 2>/dev/null || fail "VERSIONS: MERGERFS_VERSION is not $mf_pin ($(cat "$V" 2>&1 | tr '\n' ' '))"
grep -qx "SNAPRAID_VERSION=$sr_pin" "$V" 2>/dev/null || fail "VERSIONS: SNAPRAID_VERSION is not $sr_pin ($(cat "$V" 2>&1 | tr '\n' ' '))"

if [ "$FAILS" = 0 ]; then echo "image OK: $RAW"; else echo "$FAILS check(s) FAILED: $RAW"; fi
[ "$FAILS" = 0 ]
