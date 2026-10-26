#!/bin/sh
set -u
# Config/log location. install.sh records it in /etc/default/mergerfs-snapraid
# (persistent /etc), so AppData may live on a second disk (forum #21).
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}" ] && . "${MSR_DEFAULTS:-/etc/default/mergerfs-snapraid}"
ENV_FILE="${APP_DIR}/config/pool.env"
if [ -f "$ENV_FILE" ]; then
    # /DATA/AppData is writable by everyone on ZimaOS 1.8 (0777, no sticky bit; KB §79.11 of the
    # lintux notes): root reads pool.env/snapraid.conf from APP_DIR, so the folder is checked first —
    # sticky bit on its parent, refused when it is a symlink, not root's or writable by others.
    # refused: pool.env is not read, the default mountpoint is still unmounted
    if sh "${MSR_GUARD:-$(dirname "$0")/appdata-guard.sh}" --no-create "$APP_DIR"; then
        # shellcheck disable=SC1090
        . "$ENV_FILE"
    else
        echo "pool.env not read (folder check refused), unmounting the default mountpoint"
    fi
fi
: "${MOUNTPOINT:=/DATA/Storage}"

if mountpoint -q "$MOUNTPOINT"; then
    umount "$MOUNTPOINT" && echo "unmounted $MOUNTPOINT"
else
    echo "mergerfs pool not mounted at $MOUNTPOINT"
fi
