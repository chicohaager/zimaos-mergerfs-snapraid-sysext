#!/bin/sh
# Assemble a systemd-sysext .raw image for ZimaOS containing mergerfs + snapraid.
# Usage: ./build-sysext.sh <amd64|arm64>
# Requires: ./out/snapraid-<arch> (from build-snapraid.sh), mksquashfs, curl.
# Output: ./out/mergerfs-snapraid_<arch>.raw  (+ appends SHA256 to ./out/SHA256SUMS)
#
# sysext rules honoured here:
#  - systemd-sysext merges ONLY /usr (+ /opt). Everything lives under usr/.
#  - mount.mergerfs ships in usr/sbin/ (NOT /sbin) so it lands at /sbin via the
#    /sbin -> /usr/sbin usrmerge symlink. (Optional: the pool service calls the
#    mergerfs binary directly, so mount.mergerfs is only needed for `mount -t`.)
#  - extension-release uses ID=_any so the image survives ZimaOS minor updates
#    without re-install; ARCHITECTURE guards against wrong-arch merges.
set -eu

ARCH="${1:?usage: build-sysext.sh <amd64|arm64>}"
MERGERFS_VERSION="${MERGERFS_VERSION:-2.42.0}"
NAME="mergerfs-snapraid"                 # installed image name; fixed across archs
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/out"
TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
mkdir -p "$OUT"

# systemd architecture token (NOT the dpkg arch)
case "$ARCH" in
    amd64) SD_ARCH="x86-64" ;;
    arm64) SD_ARCH="arm64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# 1) mergerfs static tarball -> tree (ships usr/local/... and sbin/...)
# Pinned SHA256 of the official static tarballs — verify the download before it is
# baked into a root-privileged image (supply-chain integrity). Update on version bump.
case "${MERGERFS_VERSION}-${ARCH}" in
    2.42.0-amd64) MERGERFS_SHA256=0cf8692e1687c8a1140c714966c6f5f4b498a1537f1a0bef5665082ecb35fc12 ;;
    2.42.0-arm64) MERGERFS_SHA256=da318afbf109f025a41e9be86de5ebbdfb879546abf4cb5176c8c15881b7cf05 ;;
    *) MERGERFS_SHA256="" ;;
esac
curl -fSL -o "${TREE}/mergerfs.tar.gz" \
    "https://github.com/trapexit/mergerfs/releases/download/${MERGERFS_VERSION}/mergerfs-${MERGERFS_VERSION}-static-linux_${ARCH}.tar.gz"
if [ -n "$MERGERFS_SHA256" ]; then
    echo "${MERGERFS_SHA256}  ${TREE}/mergerfs.tar.gz" | sha256sum -c - \
        || { echo "mergerfs tarball checksum FAILED — aborting"; exit 1; }
else
    echo "WARNING: no pinned SHA256 for mergerfs ${MERGERFS_VERSION}/${ARCH} — integrity NOT verified" >&2
fi
tar -xzf "${TREE}/mergerfs.tar.gz" -C "$TREE"
rm -f "${TREE}/mergerfs.tar.gz"

# Relocate everything onto /usr/{bin,lib,sbin}. On ZimaOS /usr/local/bin does NOT
# exist and the default PATH is only /usr/bin:/usr/sbin, so the binaries MUST live
# in /usr/bin (verified on a ZimaCube Pro; this is what the tailscale/cron modules do).
# sysext merges only /usr. The man page under usr/local/share is dropped (unneeded).
if [ -d "${TREE}/usr/local" ]; then
    mkdir -p "${TREE}/usr/bin" "${TREE}/usr/lib"
    [ -d "${TREE}/usr/local/bin" ] && cp -a "${TREE}/usr/local/bin/." "${TREE}/usr/bin/"
    [ -d "${TREE}/usr/local/lib" ] && cp -a "${TREE}/usr/local/lib/." "${TREE}/usr/lib/"
    rm -rf "${TREE}/usr/local"
fi
# mount.mergerfs ships in top-level /sbin -> usr/sbin (/sbin -> /usr/sbin symlink)
if [ -f "${TREE}/sbin/mount.mergerfs" ]; then
    mkdir -p "${TREE}/usr/sbin"
    mv "${TREE}/sbin/mount.mergerfs" "${TREE}/usr/sbin/mount.mergerfs"
    rmdir "${TREE}/sbin" 2>/dev/null || true
fi

# 2) static snapraid -> usr/bin/snapraid
install -D -m 0755 "${OUT}/snapraid-${ARCH}" "${TREE}/usr/bin/snapraid"

# 3) extension-release (filename suffix MUST equal the installed image name)
mkdir -p "${TREE}/usr/lib/extension-release.d"
cat > "${TREE}/usr/lib/extension-release.d/extension-release.${NAME}" <<EOF
ID=_any
ARCHITECTURE=${SD_ARCH}
EOF

# 4) pack squashfs (root-owned, reproducible-ish)
# IMPORTANT: gzip, NOT zstd. The ZimaOS kernel's SquashFS only supports
# gzip/lz4/lzo (CONFIG_SQUASHFS_ZSTD/XZ are not set). A zstd .raw fails the
# merge with "Failed to mount dissected image: Invalid argument". (ZimaOS KB §18.3)
RAW="${OUT}/${NAME}_${ARCH}.raw"
rm -f "$RAW"
mksquashfs "$TREE" "$RAW" -all-root -comp gzip -noappend -quiet

# 5) checksum — replace this raw's line (never accumulate stale duplicates, which
#    would make install.sh's `sha256sum -c` fail on the old hash after a rebuild).
( cd "$OUT"
  touch SHA256SUMS
  grep -v " $(basename "$RAW")\$" SHA256SUMS > SHA256SUMS.tmp 2>/dev/null || true
  sha256sum "$(basename "$RAW")" >> SHA256SUMS.tmp
  mv SHA256SUMS.tmp SHA256SUMS )
echo "built: $RAW"
sha256sum "$RAW"
