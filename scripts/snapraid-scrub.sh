#!/bin/sh
# Scrub a rolling portion of the array (12% older than 10 days by default).
set -u
BIN=/usr/bin/snapraid
CONF=/DATA/AppData/mergerfs-snapraid/config/snapraid.conf
LOGDIR=/DATA/AppData/mergerfs-snapraid/logs
SCRUB_PERCENT="${SCRUB_PERCENT:-12}"
SCRUB_OLDER="${SCRUB_OLDER:-10}"

mkdir -p "$LOGDIR"
LOG="${LOGDIR}/scrub-$(date +%F-%H%M%S).log"
exec >>"$LOG" 2>&1

echo "=== snapraid scrub -p ${SCRUB_PERCENT} -o ${SCRUB_OLDER} $(date -Is) ==="
"$BIN" -c "$CONF" scrub -p "$SCRUB_PERCENT" -o "$SCRUB_OLDER"
echo "=== done $(date -Is) ==="
