#!/bin/sh
# Install the mergerfs+snapraid sysext on ZimaOS.
# Run as root from the repo root, with the built .raw images present in build/out/.
# Idempotent. Re-run after a ZimaOS update if the merge ever drops (ID=_any should
# normally prevent that).
set -eu

NAME="mergerfs-snapraid"
HERE="$(cd "$(dirname "$0")" && pwd)"
RAW_DIR="${HERE}/build/out"
APP="/DATA/AppData/${NAME}"
EXT_DIR="/var/lib/extensions"
UNIT_DIR="/etc/systemd/system"

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }

# 1) preflight
[ -c /dev/fuse ] || { echo "/dev/fuse missing — FUSE not available"; exit 1; }
case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
esac
RAW="${RAW_DIR}/${NAME}_${ARCH}.raw"
[ -f "$RAW" ] || { echo "image not found: $RAW (run build/build-snapraid.sh + build/build-sysext.sh $ARCH)"; exit 1; }

# 2) verify checksum against SHA256SUMS if present
if [ -f "${RAW_DIR}/SHA256SUMS" ]; then
    ( cd "$RAW_DIR" && grep " $(basename "$RAW")\$" SHA256SUMS | sha256sum -c - ) \
        || { echo "checksum verification FAILED for $(basename "$RAW")"; exit 1; }
    echo "checksum OK"
else
    echo "WARNING: no SHA256SUMS found, skipping checksum verification"
fi

# 3) place + merge sysext
mkdir -p "$EXT_DIR"
cp -f "$RAW" "${EXT_DIR}/${NAME}.raw"
systemd-sysext refresh
systemd-sysext status | grep -q "$NAME" || echo "WARNING: $NAME not listed in sysext status (merge may have failed — see README troubleshooting)"

# 4) smoke test the merged binaries
/usr/bin/mergerfs --version >/dev/null 2>&1 && echo "mergerfs: $(/usr/bin/mergerfs --version 2>&1 | head -1)" \
    || echo "WARNING: mergerfs not runnable after merge"
/usr/bin/snapraid --version >/dev/null 2>&1 && echo "snapraid: $(/usr/bin/snapraid --version 2>&1 | head -1)" \
    || echo "WARNING: snapraid not runnable after merge"

# 5) app dir, scripts, config templates (never overwrite existing config)
mkdir -p "${APP}/config" "${APP}/scripts" "${APP}/logs"
cp -f "${HERE}/scripts/"*.sh "${APP}/scripts/"
chmod +x "${APP}/scripts/"*.sh
# mergerfs-tool.sh builds its runner image from this Dockerfile; ship it next to the
# scripts so the wrapper finds it post-install (build/ is not part of the app dir).
cp -f "${HERE}/build/Dockerfile.mergerfs-tools" "${APP}/scripts/" 2>/dev/null || true
if [ -f "${APP}/config/pool.env" ]; then
    # A reinstall (e.g. after an earlier failed install) KEEPS the existing pool.env
    # so snapraid.conf etc. are preserved. But a stale pool.env with wrong BRANCHES or
    # missing branches-mount-timeout will reproduce the boot race — warn loudly.
    echo "NOTE: keeping existing ${APP}/config/pool.env (not overwritten)."
    grep -q "branches-mount-timeout" "${APP}/config/pool.env" \
        || echo "  WARNING: pool.env has no branches-mount-timeout — compare it against config/pool.env.example"
else
    cp "${HERE}/config/pool.env.example" "${APP}/config/pool.env"
fi
[ -f "${APP}/config/snapraid.conf" ] || cp "${HERE}/config/snapraid.conf.example" "${APP}/config/snapraid.conf"

# Harden: pool.env is shell-sourced as ROOT at boot and the scripts run as ROOT via
# systemd. /DATA/AppData can be group/world-writable on ZimaOS, so a non-root user
# able to write these would gain root code execution. Lock them down.
chown -R root:root "${APP}/config" "${APP}/scripts" 2>/dev/null || true
chmod -R go-w "${APP}/config" "${APP}/scripts"

# 6) systemd units
cp -f "${HERE}/units/"*.service "${HERE}/units/"*.timer "$UNIT_DIR/"
systemctl daemon-reload
systemctl enable mergerfs-pool.service mergerfs-pool-watchdog.timer \
    snapraid-sync.timer snapraid-scrub.timer >/dev/null 2>&1 || true

cat <<EOF

Installed.

NEXT STEPS (edit before first real use):
  1. ${APP}/config/pool.env       — set BRANCHES (data disks, NOT parity) + MOUNTPOINT
  2. ${APP}/config/snapraid.conf  — set parity/content/data to UNDERLYING disks
  3. Start the pool now:   systemctl start mergerfs-pool.service
  4. First parity build:   ${APP}/scripts/snapraid-sync.sh   (or: snapraid -c .../snapraid.conf sync)

Timers: snapraid-sync (daily 04:00), snapraid-scrub (Sun 05:00).
Disk failure? Recover with: ${APP}/scripts/replace-disk.sh <data-name>  (see README).
Filesystem note: ext4/xfs strongly recommended on data+parity disks. exFAT/NTFS
lose POSIX perms/xattrs/hardlinks and degrade SnapRAID — reformat before trusting.
After a ZimaOS update, if the pool/binaries vanish: re-run this install.sh.
EOF
