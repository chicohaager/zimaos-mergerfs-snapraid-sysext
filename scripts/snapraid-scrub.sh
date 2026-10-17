#!/bin/sh
# Scrub a rolling portion of the array (12% older than 10 days by default).
set -u
# Config/log location. install.sh records it in /etc/default/mergerfs-snapraid
# (persistent /etc), so AppData may live on a second disk (forum #21).
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}" ] && . "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}"
BIN="${SNAPRAID_BIN:-/usr/bin/snapraid}"
CONF="${APP_DIR}/config/snapraid.conf"
LOGDIR="${APP_DIR}/logs"
SCRUB_PERCENT="${SCRUB_PERCENT:-12}"
SCRUB_OLDER="${SCRUB_OLDER:-10}"

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
LOG="${LOGDIR}/scrub-$(date +%F-%H%M%S).log"
exec >>"$LOG" 2>&1

echo "=== snapraid scrub -p ${SCRUB_PERCENT} -o ${SCRUB_OLDER} $(date -Is) ==="
"$BIN" -c "$CONF" scrub -p "$SCRUB_PERCENT" -o "$SCRUB_OLDER"; rc=$?
echo "=== done rc=$rc $(date -Is) ==="
exit "$rc"
