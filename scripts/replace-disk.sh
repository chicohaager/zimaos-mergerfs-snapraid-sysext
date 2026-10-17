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
# Config/log location. install.sh records it in /etc/default/mergerfs-snapraid
# (persistent /etc), so AppData may live on a second disk (forum #21).
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}" ] && . "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}"
BIN="${SNAPRAID_BIN:-/usr/bin/snapraid}"
CONF="${APP_DIR}/config/snapraid.conf"
LOGDIR="${APP_DIR}/logs"
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

# --- refuse while sync/scrub runs ------------------------------------------------
# A running snapraid holds its lock file; fix would fail half-way into the recovery.
for s in snapraid-sync.service snapraid-scrub.service; do
    if [ "$(systemctl is-active "$s" 2>/dev/null)" = active ]; then
        echo "REFUSE: $s is running — wait for it to finish (systemctl status $s), then re-run."
        exit 1
    fi
done

# --- confirm ---------------------------------------------------------------------
echo
echo "About to RECOVER data disk '$NAME' onto $DISK_PATH ($FSTYPE)."
echo "Replacement should be the freshly-mounted blank disk. The old disk must be GONE."
printf "Type the data name '%s' to proceed: " "$NAME"
read -r CONFIRM
[ "$CONFIRM" = "$NAME" ] || { echo "aborted (got '$CONFIRM')"; exit 1; }

# --- step 2: quiesce -------------------------------------------------------------
# The marker is written BEFORE anything is stopped and removed only after a complete
# fix -> check -> sync. While it exists, snapraid-sync.sh / snapraid-scrub.sh refuse:
# a sync after a failed or interrupted fix would overwrite the parity a retry needs.
# Stopping the timers alone is not enough — they are enabled and come back at boot.
MARKER="${APP_DIR}/RECOVERY-IN-PROGRESS"
{
    echo "replace-disk.sh $NAME started $(date -Is)"
    echo "log: $REPLACE_LOG"
    echo "While this file exists, scheduled snapraid sync/scrub refuse to run."
    echo "Re-run replace-disk.sh $NAME to retry; it removes this file on success."
} > "$MARKER"

# Restore trap: the pool always comes back (data stays reachable); the timers only
# after success — on failure they stay stopped and the marker stays.
restore_services() {
    rc=$1
    echo "--- restoring pool ---"
    if [ -x "${SELF_DIR}/start-pool.sh" ]; then "${SELF_DIR}/start-pool.sh" || true; fi
    if [ "$rc" = 0 ]; then
        rm -f "$MARKER"
        echo "--- re-arming snapraid timers ---"
        systemctl start snapraid-sync.timer snapraid-scrub.timer || true
    else
        echo "!!! recovery FAILED (exit $rc). Sync/scrub stay BLOCKED by $MARKER"
        echo "    so the parity needed for a retry is not overwritten. Next steps:"
        echo "      1. read $REPLACE_LOG (snapraid fix/check output)"
        echo "      2. fix the cause, then re-run: $0 $NAME"
        echo "    Only if you deliberately give up on the missing files: rm $MARKER"
        echo "    and systemctl start snapraid-sync.timer snapraid-scrub.timer"
    fi
}
trap 'rc=$?; restore_services "$rc"; exit $rc' EXIT

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

# step 5 (remove marker, restore pool + timers) is handled by the EXIT trap above.
echo "=== replace-disk $NAME done $(date -Is) ==="
echo "Verify: snapraid -c $CONF status   (expect no errors, 100% scrubbed over time)"
