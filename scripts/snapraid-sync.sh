#!/bin/sh
# SnapRAID sync with a mass-deletion guard: if `diff` reports more removed files
# than DELETE_THRESHOLD, abort instead of syncing (prevents parity from being
# overwritten after an accidental bulk delete / disk dropout). Basic awk parse of
# the diff summary — review thresholds for your array. Confidence: wahrscheinlich.
set -u
BIN=/usr/bin/snapraid
CONF=/DATA/AppData/mergerfs-snapraid/config/snapraid.conf
LOGDIR=/DATA/AppData/mergerfs-snapraid/logs
DELETE_THRESHOLD="${DELETE_THRESHOLD:-200}"

mkdir -p "$LOGDIR"
LOG="${LOGDIR}/sync-$(date +%F-%H%M%S).log"
exec >>"$LOG" 2>&1

echo "=== snapraid diff $(date -Is) ==="
DIFF="$("$BIN" -c "$CONF" diff 2>&1)"; RC=$?   # 0 = no diff, 2 = differences present
echo "$DIFF"

# Fail CLOSED. snapraid diff returns 0 (no changes) or 2 (changes). Any other code
# is an error (a disk dropped, bad config, ...). The old code swallowed the exit
# code with `|| true`; a diff that errored before printing its summary then parsed
# as "0 removed" and the guard let the sync overwrite parity — exactly the dropout
# scenario this guard exists to catch. So: never sync unless diff cleanly succeeded.
if [ "$RC" != 0 ] && [ "$RC" != 2 ]; then
    echo "ABORT: 'snapraid diff' exited $RC (disk missing / config error?) — not syncing."
    exit 1
fi
# The summary block must be present; its absence means unexpected output -> abort.
if ! printf '%s\n' "$DIFF" | grep -qE '^[[:space:]]*[0-9]+ equal$'; then
    echo "ABORT: no diff summary found in snapraid output — not syncing (fail-closed)."
    exit 1
fi

REMOVED="$(printf '%s\n' "$DIFF" | awk '$2=="removed"{n=$1} END{print n+0}')"
echo "removed=$REMOVED threshold=$DELETE_THRESHOLD"
if [ "$REMOVED" -gt "$DELETE_THRESHOLD" ]; then
    echo "ABORT: $REMOVED removed > $DELETE_THRESHOLD — sync skipped (possible data loss)."
    exit 1
fi

echo "=== snapraid sync $(date -Is) ==="
"$BIN" -c "$CONF" sync
echo "=== done $(date -Is) ==="
