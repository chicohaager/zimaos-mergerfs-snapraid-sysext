#!/bin/sh
# Mount the mergerfs pool. Idempotent: no-op if already mounted.
set -eu
ENV_FILE=/DATA/AppData/mergerfs-snapraid/config/pool.env
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${MOUNTPOINT:?set MOUNTPOINT in pool.env}"
: "${BRANCHES:?set BRANCHES in pool.env}"
: "${OPTS:?set OPTS in pool.env}"

mkdir -p "$MOUNTPOINT"
if mountpoint -q "$MOUNTPOINT"; then
    echo "mergerfs pool already mounted at $MOUNTPOINT"
    exit 0
fi

# mergerfs daemonises by default; oneshot+RemainAfterExit tracks the mount state.
/usr/bin/mergerfs -o "$OPTS" "$BRANCHES" "$MOUNTPOINT"
echo "mergerfs pool mounted at $MOUNTPOINT"
