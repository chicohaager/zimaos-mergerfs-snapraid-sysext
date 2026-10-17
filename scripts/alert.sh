#!/bin/sh
# Failure alert, run by mergerfs-snapraid-alert@<unit>.service via OnFailure= on the
# pool, sync and scrub units. A failed unit is otherwise only visible to someone who
# runs `systemctl --failed` — e.g. a sync blocked by the deletion guard every night.
#
# Always: writes $APP_DIR/logs/ALERT-<unit>-<time>.txt (visible in the ZimaOS Files
# app) with the unit's last journal lines. Optional: NOTIFY_CMD in
# /etc/default/mergerfs-snapraid is run with ALERT_UNIT and ALERT_FILE set, e.g.
#   NOTIFY_CMD='curl -s -d "$ALERT_UNIT failed on $(hostname)" https://ntfy.sh/<topic>'
set -u
UNIT="${1:?usage: alert.sh <unit>}"
# Config/log location. install.sh records it in /etc/default/mergerfs-snapraid
# (persistent /etc), so AppData may live on a second disk (forum #21).
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}" ] && . "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}"

echo "mergerfs-snapraid ALERT: $UNIT failed"
ALERT_FILE=""
# Only write if APP_DIR exists: a pool that failed because its disk is missing must
# not get a logs/ dir created on the bare mountpoint directory.
if [ -d "$APP_DIR" ]; then
    mkdir -p "$APP_DIR/logs"
    ALERT_FILE="$APP_DIR/logs/ALERT-$UNIT-$(date +%F-%H%M%S).txt"
    {
        echo "$UNIT failed on $(hostname) at $(date -Is)"
        echo "Last journal lines:"
        journalctl -u "$UNIT" -n 40 --no-pager 2>&1
    } > "$ALERT_FILE"
    echo "details: $ALERT_FILE"
else
    echo "APP_DIR=$APP_DIR not present — no alert file written"
fi
if [ -n "${NOTIFY_CMD:-}" ]; then
    ALERT_UNIT="$UNIT" ALERT_FILE="$ALERT_FILE" sh -c "$NOTIFY_CMD"
    echo "NOTIFY_CMD exit=$?"
fi
exit 0
