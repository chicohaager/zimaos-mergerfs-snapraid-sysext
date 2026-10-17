#!/bin/sh
# Install the mergerfs+snapraid sysext on ZimaOS.
# Run as root from the repo root, with the built .raw images present in build/out/.
#
# Usage: ./install.sh [--app-dir <dir>]
#   --app-dir  where config/ and logs/ live (default DEFAULT_APP_DIR below, or the
#              value already recorded in /etc/default/mergerfs-snapraid).
#              May be on a second disk that ZimaOS mounts late, e.g. a SATA SSD.
# Idempotent. Re-run after a ZimaOS update if the merge ever drops (ID=_any should
# normally prevent that).
set -eu

NAME="mergerfs-snapraid"
HERE="$(cd "$(dirname "$0")" && pwd)"
RAW_DIR="${HERE}/build/out"
DEFAULT_APP_DIR=/DATA/AppData/mergerfs-snapraid
DEFAULTS="/etc/default/${NAME}"
LIBEXEC="/usr/lib/${NAME}"
EXT_DIR="/var/lib/extensions"
UNIT_DIR="/etc/systemd/system"

ARG_APP_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app-dir) ARG_APP_DIR="${2:?--app-dir needs a directory}"; shift 2 ;;
        *) echo "usage: $0 [--app-dir <dir>]"; exit 1 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }

# 0) where config + logs live. /etc is persistent on ZimaOS; every script and the
#    units read APP_DIR from this one file instead of a hard-coded /DATA path.
#    Precedence: --app-dir > $DEFAULTS > path found in already-installed units > default.
APP_DIR="$DEFAULT_APP_DIR"
APP_DIR_FROM=default
if [ -f "$DEFAULTS" ]; then
    # shellcheck disable=SC1090
    . "$DEFAULTS"; APP_DIR_FROM="$DEFAULTS"
else
    # Older installs had no $DEFAULTS; users who moved AppData (forum #21: a SATA SSD)
    # wrote their path straight into the units. Recover it from there, or a plain
    # re-run would fall back to /DATA/AppData and orphan their config.
    found="$(for u in mergerfs-pool.service mergerfs-pool-watchdog.service \
                       snapraid-sync.service snapraid-scrub.service; do
                 [ -f "$UNIT_DIR/$u" ] || continue
                 grep -o -E "/[^ '\"]*/(scripts/[A-Za-z0-9_.-]+\.sh|config/snapraid\.conf)" "$UNIT_DIR/$u" \
                     | sed -E 's#/(scripts/[^/]+|config/snapraid\.conf)$##'
             done | sort -u)"
    case "$(printf '%s\n' "$found" | grep -c .)" in
        0) ;;
        1) APP_DIR="$found"; APP_DIR_FROM="the installed units" ;;
        *) echo "ERROR: the installed units name different AppData paths:"
           printf '%s\n' "$found" | sed 's/^/         /'
           echo "       Re-run with the one that holds your config:  $0 --app-dir <dir>"
           exit 1 ;;
    esac
fi
if [ -n "$ARG_APP_DIR" ]; then APP_DIR="$ARG_APP_DIR"; APP_DIR_FROM="--app-dir"; fi
# A path taken over from old units must already exist: if its disk is not mounted,
# mkdir below would create config/ on the bare mountpoint directory instead.
if [ "$APP_DIR_FROM" = "the installed units" ] && [ ! -d "$APP_DIR" ]; then
    echo "ERROR: your units use APP_DIR=$APP_DIR, but it does not exist right now"
    echo "       (disk not mounted?). Mount it and re-run, or pass:  $0 --app-dir <dir>"
    exit 1
fi
echo "APP_DIR=$APP_DIR (from $APP_DIR_FROM)"
case "$APP_DIR" in
    /*) ;;
    *) echo "app dir must be an absolute path: $APP_DIR"; exit 1 ;;
esac
case "$APP_DIR" in
    *[[:space:]]* | *\'* | *\"* | *\$* | *\`* | *\\*) echo "app dir must not contain spaces or quotes: $APP_DIR"; exit 1 ;;
esac
APP="$APP_DIR"

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

# 4) smoke test the merged binaries + the scripts the units execute
[ -x "${LIBEXEC}/start-pool.sh" ] || {
    echo "ERROR: ${LIBEXEC}/start-pool.sh missing — this .raw predates the scripts-in-sysext"
    echo "       layout; rebuild it (build/build-sysext.sh) or download a current release."
    exit 1; }
/usr/bin/mergerfs --version >/dev/null 2>&1 && echo "mergerfs: $(/usr/bin/mergerfs --version 2>&1 | head -1)" \
    || echo "WARNING: mergerfs not runnable after merge"
/usr/bin/snapraid --version >/dev/null 2>&1 && echo "snapraid: $(/usr/bin/snapraid --version 2>&1 | head -1)" \
    || echo "WARNING: snapraid not runnable after merge"

# 5) app dir, config templates (never overwrite existing config)
mkdir -p "$(dirname "$DEFAULTS")"
# Only the APP_DIR line is install.sh's; keep every other setting a user added there
# (CONFIG_WAIT, DELETE_THRESHOLD, NOTIFY_CMD, ...).
if [ -f "$DEFAULTS" ]; then
    grep -v '^APP_DIR=' "$DEFAULTS" > "$DEFAULTS.new" || true
else
    cat > "$DEFAULTS.new" <<'EOF'
# mergerfs-snapraid settings — read by the scripts and units. install.sh only
# rewrites the APP_DIR line; everything else here is yours. Optional:
#CONFIG_WAIT=300          # boot: seconds to wait for APP_DIR's pool.env
#DELETE_THRESHOLD=200     # sync aborts above this many removed files
#NOTIFY_CMD='...'         # run on a failed pool/sync/scrub ($ALERT_UNIT, $ALERT_FILE)
EOF
fi
printf "APP_DIR='%s'\n" "$APP_DIR" >> "$DEFAULTS.new"
chmod 0644 "$DEFAULTS.new"
mv "$DEFAULTS.new" "$DEFAULTS"
echo "APP_DIR=$APP_DIR (recorded in $DEFAULTS)"
mkdir -p "${APP}/config" "${APP}/scripts" "${APP}/logs"
# The scripts ship read-only in the sysext (${LIBEXEC}); ${APP}/scripts keeps symlinks
# so the documented paths (${APP}/scripts/replace-disk.sh ...) keep working.
# Earlier installs put real copies here — possibly hand-edited (forum #21) — so move
# them aside instead of overwriting them.
BACKUP="${APP}/scripts/.replaced-$(date +%Y%m%d-%H%M%S)"
for src in "${LIBEXEC}/"*; do
    dst="${APP}/scripts/$(basename "$src")"
    if [ -f "$dst" ] && [ ! -L "$dst" ]; then
        mkdir -p "$BACKUP"
        mv "$dst" "$BACKUP/"
    fi
    ln -sfn "$src" "$dst"
done
[ -d "$BACKUP" ] && echo "NOTE: previous script copies moved to $BACKUP (now symlinks into ${LIBEXEC})."
if [ -f "${APP}/config/pool.env" ]; then
    # A reinstall (e.g. after an earlier failed install) KEEPS the existing pool.env
    # so snapraid.conf etc. are preserved. But a stale pool.env with wrong BRANCHES or
    # missing branches-mount-timeout will reproduce the boot race — warn loudly.
    echo "NOTE: keeping existing ${APP}/config/pool.env (not overwritten)."
    grep -q "branches-mount-timeout" "${APP}/config/pool.env" \
        || echo "  WARNING: pool.env has no branches-mount-timeout — compare it against config/pool.env.example"
    grep -q "branches-mount-timeout-fail=true" "${APP}/config/pool.env" \
        || echo "  NOTE: consider adding branches-mount-timeout-fail=true to OPTS (see config/pool.env.example)"
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
# cp keeps the source mode; a checkout/copy with +x makes systemd warn "marked
# executable" on every reload (forum #21 journal) — normalise to 0644.
# Hand-edited units (forum #21: AppData path, own watchdog loop) are replaced by the
# shipped ones — keep a copy of every installed unit that differs.
UNIT_BACKUP="${APP}/units-backup-$(date +%Y%m%d-%H%M%S)"
for u in "${HERE}/units/"*.service "${HERE}/units/"*.timer; do
    old="$UNIT_DIR/$(basename "$u")"
    if [ -f "$old" ] && ! cmp -s "$u" "$old"; then
        mkdir -p "$UNIT_BACKUP"
        cp -p "$old" "$UNIT_BACKUP/"
    fi
done
[ -d "$UNIT_BACKUP" ] && echo "NOTE: previous unit files differed — copies kept in $UNIT_BACKUP"
for u in "${HERE}/units/"*.service "${HERE}/units/"*.timer; do
    cp -f "$u" "$UNIT_DIR/"
    chmod 0644 "$UNIT_DIR/$(basename "$u")"
done
systemctl daemon-reload
# The pool is only enabled: it would mount the example BRANCHES until pool.env is edited.
systemctl enable mergerfs-pool.service
# Timers are enabled AND started. `enable` alone arms them only at the next boot — on
# .143 a reinstall left the snapraid timers enabled-but-inactive, so no sync ran.
systemctl enable --now mergerfs-pool-watchdog.timer snapraid-sync.timer snapraid-scrub.timer
for t in snapraid-sync.timer snapraid-scrub.timer; do
    [ "$(systemctl is-active "$t")" = active ] || echo "WARNING: $t is not active — check: systemctl status $t"
done

cat <<EOF

Installed.

NEXT STEPS (edit before first real use):
  1. ${APP}/config/pool.env       — set BRANCHES (data disks, NOT parity) + MOUNTPOINT
  2. ${APP}/config/snapraid.conf  — set parity/content/data to UNDERLYING disks
  3. Start the pool now:   systemctl start mergerfs-pool.service
  4. First parity build:   ${APP}/scripts/snapraid-sync.sh   (or: snapraid -c .../snapraid.conf sync)

Config location: APP_DIR=${APP_DIR} (change with: ./install.sh --app-dir <dir>).
At boot the pool waits up to CONFIG_WAIT=300s for it (set CONFIG_WAIT=... in ${DEFAULTS}).

Timers (active now): snapraid-sync (daily 04:00), snapraid-scrub (Sun 05:00).
Until edited, pool/sync/scrub refuse configs identical to the shipped examples.
Disk failure? Recover with: ${APP}/scripts/replace-disk.sh <data-name>  (see README).
Filesystem note: ext4/xfs strongly recommended on data+parity disks. exFAT/NTFS
lose POSIX perms/xattrs/hardlinks and degrade SnapRAID — reformat before trusting.
After a ZimaOS update, if the pool/binaries vanish: re-run this install.sh.
EOF
