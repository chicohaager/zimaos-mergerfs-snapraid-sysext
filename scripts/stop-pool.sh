#!/bin/sh
set -u
ENV_FILE=/DATA/AppData/mergerfs-snapraid/config/pool.env
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${MOUNTPOINT:=/DATA/Storage}"

if mountpoint -q "$MOUNTPOINT"; then
    umount "$MOUNTPOINT" && echo "unmounted $MOUNTPOINT"
else
    echo "mergerfs pool not mounted at $MOUNTPOINT"
fi
