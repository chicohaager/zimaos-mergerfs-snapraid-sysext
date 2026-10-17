#!/bin/sh
set -u
# Config/log location. install.sh records it in /etc/default/mergerfs-snapraid
# (persistent /etc), so AppData may live on a second disk (forum #21).
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}" ] && . "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}"
ENV_FILE="${APP_DIR}/config/pool.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${MOUNTPOINT:=/DATA/Storage}"

if mountpoint -q "$MOUNTPOINT"; then
    umount "$MOUNTPOINT" && echo "unmounted $MOUNTPOINT"
else
    echo "mergerfs pool not mounted at $MOUNTPOINT"
fi
