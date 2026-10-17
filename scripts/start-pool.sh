#!/bin/sh
# Mount the mergerfs pool. Idempotent: no-op if already mounted.
set -eu
# Config/log location. install.sh records it in /etc/default/mergerfs-snapraid
# (persistent /etc), so AppData may live on a second disk (forum #21).
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}" ] && . "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}"
MERGERFS_BIN="${MERGERFS_BIN:-/usr/bin/mergerfs}"
SNAPRAID_BIN="${SNAPRAID_BIN:-/usr/bin/snapraid}"
ENV_FILE="${APP_DIR}/config/pool.env"

# The config may sit on a disk that ZimaOS mounts after this unit starts (AppData
# moved to a SATA SSD: forum #21 saw 203/EXEC when the scripts lived there too).
# The scripts now ship in the sysext, so only the config has to be waited for.
CONFIG_WAIT="${CONFIG_WAIT:-300}"
i=0
while [ ! -f "$ENV_FILE" ]; do
    i=$((i + 1))
    if [ "$i" -gt "$CONFIG_WAIT" ]; then
        echo "ERROR: $ENV_FILE not found after ${CONFIG_WAIT}s — is the disk holding APP_DIR=$APP_DIR mounted?"
        exit 1
    fi
    [ "$i" = 1 ] && echo "waiting for $ENV_FILE (up to ${CONFIG_WAIT}s)..."
    sleep 1
done
# The examples ship next to the scripts in the sysext. An unedited example config names
# /media/sda + /media/sdb — real disks on many ZimaOS boxes — so never act on it.
EXAMPLES_DIR="${EXAMPLES_DIR:-/usr/lib/mergerfs-snapraid}"
if [ -f "$EXAMPLES_DIR/pool.env.example" ] && cmp -s "$ENV_FILE" "$EXAMPLES_DIR/pool.env.example"; then
    echo "REFUSE: $ENV_FILE is the unedited example (BRANCHES=/media/sda:/media/sdb) — edit it first."
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${MOUNTPOINT:?set MOUNTPOINT in pool.env}"
: "${BRANCHES:?set BRANCHES in pool.env}"
: "${OPTS:?set OPTS in pool.env}"

# Sysext-merge guard. The ZimaOS base ships an ancient mergerfs (v1.5.4) at
# /usr/bin/mergerfs that rejects modern -o options (branches-mount-timeout, etc.) and
# would fail this script. snapraid is provided ONLY by this sysext, so its absence
# means the overlay has not merged yet — refuse rather than run the stale binary.
if [ ! -x "$SNAPRAID_BIN" ]; then
    echo "sysext not merged (no $SNAPRAID_BIN) — refusing to start pool against base mergerfs $("$MERGERFS_BIN" --version 2>&1 | head -1)"
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
# A `.mergerfs.branch` file marks a plain folder as an intended branch — the same
# marker mergerfs' own branches-mount-timeout check honours (fs_wait_for_mount.cpp).
branch_ready() {
    _b=$1
    mountpoint -q "$_b" && return 0
    [ -e "$_b/.mergerfs.branch" ] && return 0
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
            # An empty, unmounted dir is the not-yet-mounted disk: mounting the pool
            # now would send new files onto the filesystem underneath it.
            if [ -d "$b" ] && [ "${ALLOW_EMPTY_BRANCH:-0}" = 1 ]; then
                echo "WARNING: branch $b still empty and not mounted after ${BRANCH_WAIT}s — proceeding (ALLOW_EMPTY_BRANCH=1)"
                break
            fi
            if [ -d "$b" ]; then
                echo "ERROR: branch $b is empty and not a mountpoint after ${BRANCH_WAIT}s — refusing to mount the pool over it."
                echo "       Disk not mounted yet? Raise BRANCH_WAIT. Intentionally empty folder? touch $b/.mergerfs.branch"
                exit 1
            fi
            echo "ERROR: branch $b absent after ${BRANCH_WAIT}s — refusing to mount pool over a missing branch"
            exit 1
        fi
        [ "$i" = 1 ] && echo "waiting for branch $b to mount (up to ${BRANCH_WAIT}s)..."
        sleep 1
    done
done

# With branches-mount-timeout-fail=true mergerfs itself refuses a branch that is a plain
# folder on the mountpoint's filesystem (st_dev check) unless it carries the marker.
case ",$OPTS," in
    *,branches-mount-timeout-fail=true,*)
        mp_dev="$(stat -c %d "$MOUNTPOINT")"
        for raw in $(echo "$BRANCHES" | tr ':' ' '); do
            b=${raw%%=*}
            [ -d "$b" ] || continue
            if [ "$(stat -c %d "$b")" = "$mp_dev" ] && [ ! -e "$b/.mergerfs.branch" ]; then
                echo "NOTE: $b is on the same filesystem as $MOUNTPOINT — mergerfs will treat it as"
                echo "      not mounted and exit (branches-mount-timeout-fail). If it is meant to be a"
                echo "      plain folder branch: touch $b/.mergerfs.branch"
            fi
        done ;;
esac

# mergerfs daemonises by default; oneshot+RemainAfterExit tracks the mount state.
"$MERGERFS_BIN" -o "$OPTS" "$BRANCHES" "$MOUNTPOINT"
echo "mergerfs pool mounted at $MOUNTPOINT"
