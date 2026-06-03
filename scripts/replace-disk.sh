#!/bin/sh
# Guided SnapRAID disk replacement / recovery.
#
# Use after a data disk has failed and a *blank replacement* has been mounted at
# the SAME path the failed disk used (see snapraid.conf `data <name> <path>`).
#
# Flow (matches the SnapRAID recovery procedure):
#   1. snapraid status                       (show array health)
#   2. stop sync+scrub timers and the pool   (no writes during recovery)
#   3. confirm the replacement is mounted at the expected path, right FS, empty
#   4. snapraid -d <name> fix  ->  check  ->  sync
#   5. restart pool + timers
#
# Refuses to run if the configured path is not an actual mount, or the FS is
# exFAT/NTFS (no POSIX perms/xattrs/hardlinks -> unsafe for the array).
#
# Usage:  replace-disk.sh <data-name>        e.g.  replace-disk.sh d1
# DANGER: only run with the OLD disk physically gone and the NEW disk mounted.
set -eu

NAME="${1:-}"
BIN=/usr/bin/snapraid
CONF=/DATA/AppData/mergerfs-snapraid/config/snapraid.conf
LOGDIR=/DATA/AppData/mergerfs-snapraid/logs
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }
[ -n "$NAME" ] || { echo "usage: $0 <data-name>   (the SnapRAID data id, e.g. d1)"; exit 1; }
[ -x "$BIN" ]   || { echo "snapraid binary not found at $BIN (is the sysext merged?)"; exit 1; }
[ -f "$CONF" ]  || { echo "missing $CONF"; exit 1; }

mkdir -p "$LOGDIR"
# POSIX-safe logging: re-run ourselves once with all output teed to the logfile.
# stdin stays the terminal, so the confirmation prompt below still works.
if [ -z "${REPLACE_LOG:-}" ]; then
    REPLACE_LOG="${LOGDIR}/replace-${NAME}-$(date +%F-%H%M%S).log"
    export REPLACE_LOG
    echo "logging to $REPLACE_LOG"
    # POSIX sh has no PIPESTATUS, so `exit $?` after a pipe would return tee's
    # status, not the recovery's — a FAILED rebuild would exit 0 and any caller
    # would think it succeeded. Capture the real status via a temp file and
    # fail-closed to 1 if it is somehow missing.
    STATUS_FILE="$(mktemp "${LOGDIR}/.replace-status.XXXXXX")"
    { "$0" "$@"; echo "$?" > "$STATUS_FILE"; } 2>&1 | tee -a "$REPLACE_LOG"
    rc="$(cat "$STATUS_FILE" 2>/dev/null || echo 1)"
    rm -f "$STATUS_FILE"
    exit "${rc:-1}"
fi
echo "=== replace-disk $NAME $(date -Is) ==="

# Resolve the configured path for this data name from snapraid.conf.
DISK_PATH="$(awk -v n="$NAME" '$1=="data" && $2==n {print $3}' "$CONF" | head -1)"
[ -n "$DISK_PATH" ] || { echo "no 'data $NAME <path>' line in $CONF"; exit 1; }
echo "configured path for $NAME: $DISK_PATH"

# --- guard 1: must be an actual, separate mountpoint -----------------------------
if ! mountpoint -q "$DISK_PATH"; then
    echo "REFUSE: $DISK_PATH is not a mountpoint. Mount the replacement disk there first."
    echo "        (ZimaOS may assign a different /media/sdX letter — re-check the mount,"
    echo "         and prefer by-LABEL/by-UUID mounts for stable SnapRAID identity.)"
    exit 1
fi

# --- guard 2: filesystem must not be exFAT/NTFS ----------------------------------
FSTYPE="$(findmnt -n -o FSTYPE --target "$DISK_PATH" 2>/dev/null || stat -f -c %T "$DISK_PATH" 2>/dev/null || echo unknown)"
echo "filesystem at $DISK_PATH: $FSTYPE"
case "$FSTYPE" in
    exfat|ntfs|ntfs3|fuseblk|msdos|vfat)
        echo "REFUSE: $FSTYPE lacks POSIX perms/xattrs/hardlinks — unsafe for a SnapRAID disk."
        echo "        Reformat the replacement as ext4 or xfs and re-mount at $DISK_PATH."
        exit 1 ;;
    unknown)
        echo "WARNING: could not determine filesystem type — verify manually before continuing." ;;
esac

# --- step 1: status --------------------------------------------------------------
echo "--- snapraid status ---"
"$BIN" -c "$CONF" status || true

# --- confirm ---------------------------------------------------------------------
echo
echo "About to RECOVER data disk '$NAME' onto $DISK_PATH ($FSTYPE)."
echo "Replacement should be the freshly-mounted blank disk. The old disk must be GONE."
printf "Type the data name '%s' to proceed: " "$NAME"
read -r CONFIRM
[ "$CONFIRM" = "$NAME" ] || { echo "aborted (got '$CONFIRM')"; exit 1; }

# --- step 2: quiesce -------------------------------------------------------------
# Install a restore trap FIRST: snapraid fix/check return non-zero on errors, and
# under `set -e` that would abort BEFORE the pool/timers are restarted, leaving the
# array offline and timers disabled — the worst state to hand back mid-recovery.
# The EXIT trap restores services on every path (success and failure).
restore_services() {
    echo "--- restoring pool + timers ---"
    [ -x "${SELF_DIR}/start-pool.sh" ] && "${SELF_DIR}/start-pool.sh" || true
    systemctl start snapraid-sync.timer snapraid-scrub.timer 2>/dev/null || true
}
trap 'rc=$?; [ "$rc" = 0 ] || echo "!!! recovery FAILED (exit $rc) — restoring services so the array is not left offline"; restore_services; exit $rc' EXIT

echo "--- stopping timers + pool ---"
systemctl stop snapraid-sync.timer snapraid-scrub.timer 2>/dev/null || true
[ -x "${SELF_DIR}/stop-pool.sh" ] && "${SELF_DIR}/stop-pool.sh" || true

# --- step 4: fix -> check -> sync ------------------------------------------------
# fix -d <name>  rebuilds ONLY this disk from parity + the surviving disks.
echo "--- snapraid fix -d $NAME (rebuild from parity) ---"
"$BIN" -c "$CONF" -d "$NAME" fix

echo "--- snapraid check (verify the rebuild) ---"
"$BIN" -c "$CONF" check

echo "--- snapraid sync (re-align parity) ---"
"$BIN" -c "$CONF" sync

# step 5 (restore pool + timers) is handled by the EXIT trap above.
echo "=== replace-disk $NAME done $(date -Is) ==="
echo "Verify: snapraid -c $CONF status   (expect no errors, 100% scrubbed over time)"
