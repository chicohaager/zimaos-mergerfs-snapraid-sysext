#!/bin/sh
# SnapRAID sync with a mass-deletion guard: if `diff` reports more removed files
# than DELETE_THRESHOLD, abort instead of syncing (prevents parity from being
# overwritten after an accidental bulk delete / disk dropout). Basic awk parse of
# the diff summary — review thresholds for your array.
#
# Usage: snapraid-sync.sh [--allow-deletes N]
#   DELETE_THRESHOLD (default 200) can be set in /etc/default/mergerfs-snapraid.
#   --allow-deletes N releases ONE run with up to N removed files (forum #20: after an
#   intended clean-up of 8000 files the guard blocked every nightly sync).
set -u
ALLOW_DELETES=""
case "${1:-}" in
    --allow-deletes)
        ALLOW_DELETES="${2:-}"
        case "$ALLOW_DELETES" in ''|*[!0-9]*) echo "usage: $0 [--allow-deletes N]"; exit 1 ;; esac ;;
    "") ;;
    *) echo "usage: $0 [--allow-deletes N]"; exit 1 ;;
esac
# Config/log location. install.sh records it in /etc/default/mergerfs-snapraid
# (persistent /etc), so AppData may live on a second disk (forum #21).
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}" ] && . "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}"
BIN="${SNAPRAID_BIN:-/usr/bin/snapraid}"
CONF="${APP_DIR}/config/snapraid.conf"
LOGDIR="${APP_DIR}/logs"
DELETE_THRESHOLD="${DELETE_THRESHOLD:-200}"

# Check before mkdir: an absent APP_DIR means its disk is not mounted, and creating
# logs/ would write onto the bare mountpoint directory underneath it.
[ -f "$CONF" ] || { echo "missing $CONF — is the disk holding APP_DIR=$APP_DIR mounted?"; exit 1; }
# The examples ship next to the scripts in the sysext. An unedited example config names
# /media/sda + /media/sdb — real disks on many ZimaOS boxes — so never act on it.
EXAMPLES_DIR="${EXAMPLES_DIR:-/usr/lib/mergerfs-snapraid}"
if [ -f "$EXAMPLES_DIR/snapraid.conf.example" ] && cmp -s "$CONF" "$EXAMPLES_DIR/snapraid.conf.example"; then
    echo "REFUSE: $CONF is the unedited example (data disks /media/sda, /media/sdb) — edit it first."
    exit 1
fi
# replace-disk.sh marker: a disk recovery failed or is running — syncing now would
# overwrite parity that a retry still needs.
if [ -f "${APP_DIR}/RECOVERY-IN-PROGRESS" ]; then
    echo "REFUSE: ${APP_DIR}/RECOVERY-IN-PROGRESS exists — disk recovery not finished. See that file."
    exit 1
fi
mkdir -p "$LOGDIR"
LOG="${LOGDIR}/sync-$(date +%F-%H%M%S).log"
# fd 3 keeps the original stdout (the journal under systemd): ABORT reasons go to the
# log AND there, so `systemctl status` and the failure alert show why.
exec 3>&1
exec >>"$LOG" 2>&1
say() { echo "$*"; echo "$*" >&3; }

echo "=== snapraid diff $(date -Is) ==="
DIFF="$("$BIN" -c "$CONF" diff 2>&1)"; RC=$?   # 0 = no diff, 2 = differences present
echo "$DIFF"

# Fail CLOSED. snapraid diff returns 0 (no changes) or 2 (changes). Any other code
# is an error (a disk dropped, bad config, ...). The old code swallowed the exit
# code with `|| true`; a diff that errored before printing its summary then parsed
# as "0 removed" and the guard let the sync overwrite parity — exactly the dropout
# scenario this guard exists to catch. So: never sync unless diff cleanly succeeded.
if [ "$RC" != 0 ] && [ "$RC" != 2 ]; then
    say "ABORT: 'snapraid diff' exited $RC (disk missing / config error?) — not syncing. Log: $LOG"
    exit 1
fi
# The summary block must be present; its absence means unexpected output -> abort.
if ! printf '%s\n' "$DIFF" | grep -qE '^[[:space:]]*[0-9]+ equal$'; then
    say "ABORT: no diff summary found in snapraid output — not syncing (fail-closed). Log: $LOG"
    exit 1
fi

REMOVED="$(printf '%s\n' "$DIFF" | awk '$2=="removed"{n=$1} END{print n+0}')"
LIMIT="$DELETE_THRESHOLD"
[ -n "$ALLOW_DELETES" ] && LIMIT="$ALLOW_DELETES"
echo "removed=$REMOVED threshold=$DELETE_THRESHOLD allow-deletes=${ALLOW_DELETES:-none}"
if [ "$REMOVED" -gt "$LIMIT" ]; then
    say "ABORT: $REMOVED files removed > limit $LIMIT — sync skipped (possible data loss). Log: $LOG"
    say "       Check the 'remove' lines in that log. If the deletions are intended, release this once:"
    say "       sudo ${APP_DIR}/scripts/snapraid-sync.sh --allow-deletes $REMOVED"
    exit 1
fi

echo "=== snapraid sync $(date -Is) ==="
"$BIN" -c "$CONF" sync; rc=$?
# Exit with snapraid's status: a trailing echo used to turn a failed sync into exit 0,
# so the unit stayed green and mergerfs-tool.sh reported "sync OK".
echo "=== done rc=$rc $(date -Is) ==="
exit "$rc"
