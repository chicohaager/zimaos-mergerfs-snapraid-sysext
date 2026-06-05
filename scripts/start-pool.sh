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

# Sysext-merge guard. The ZimaOS base ships an ancient mergerfs (v1.5.4) at
# /usr/bin/mergerfs that rejects modern -o options (branches-mount-timeout, etc.) and
# would fail this script. snapraid is provided ONLY by this sysext, so its absence
# means the overlay has not merged yet — refuse rather than run the stale binary.
if [ ! -x /usr/bin/snapraid ]; then
    echo "sysext not merged (no /usr/bin/snapraid) — refusing to start pool against base mergerfs $(/usr/bin/mergerfs --version 2>&1 | head -1)"
    exit 1
fi

# How long to wait for the ZimaOS storage daemon to mount the branch disks at boot.
# Override in pool.env if your disks spin up slowly. This is the real boot-race fix:
# the sysext ordering only guarantees the mergerfs *binary* is merged, NOT that the
# /media/sdX data disks are mounted yet. Mounting the pool over an unmounted (empty)
# branch would expose an empty pool and shadow the disk when it mounts later.
BRANCH_WAIT="${BRANCH_WAIT:-90}"

mkdir -p "$MOUNTPOINT"
if mountpoint -q "$MOUNTPOINT"; then
    echo "mergerfs pool already mounted at $MOUNTPOINT"
    exit 0
fi

# A branch is "ready" if it is a mountpoint (the ZimaOS /media/sdX case) OR it is a
# non-empty directory (a populated /DATA/... branch that lives on an already-mounted
# fs and will never itself be a separate mountpoint). An empty, non-mountpoint dir is
# treated as not-yet-ready — that is exactly the unmounted /media/sdX race we guard.
branch_ready() {
    _b=$1
    mountpoint -q "$_b" && return 0
    [ -d "$_b" ] && [ -n "$(ls -A "$_b" 2>/dev/null)" ] && return 0
    return 1
}

# Wait for every concrete branch. BRANCHES is colon-separated; entries may carry a
# mergerfs =RW/=RO/=NC mode suffix. Glob branches (*, ?) can't be polled — skip them
# and let mergerfs' own branches-mount-timeout cover that case.
for raw in $(echo "$BRANCHES" | tr ':' ' '); do
    b=${raw%%=*}
    case "$b" in *'*'* | *'?'*) continue ;; esac
    i=0
    while ! branch_ready "$b"; do
        i=$((i + 1))
        if [ "$i" -ge "$BRANCH_WAIT" ]; then
            if [ -d "$b" ]; then
                echo "WARNING: branch $b still not mounted/empty after ${BRANCH_WAIT}s — proceeding anyway"
                break
            fi
            echo "ERROR: branch $b absent after ${BRANCH_WAIT}s — refusing to mount pool over a missing branch"
            exit 1
        fi
        [ "$i" = 1 ] && echo "waiting for branch $b to mount (up to ${BRANCH_WAIT}s)..."
        sleep 1
    done
done

# mergerfs daemonises by default; oneshot+RemainAfterExit tracks the mount state.
/usr/bin/mergerfs -o "$OPTS" "$BRANCHES" "$MOUNTPOINT"
echo "mergerfs pool mounted at $MOUNTPOINT"
