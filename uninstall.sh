#!/bin/sh
# Uninstall the mergerfs+snapraid sysext. PRESERVES all data, config and parity.
# Does NOT delete anything under the data disks or /DATA/AppData/mergerfs-snapraid.
set -u

NAME="mergerfs-snapraid"
APP="/DATA/AppData/${NAME}"
EXT_DIR="/var/lib/extensions"
UNIT_DIR="/etc/systemd/system"

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }

# stop + disable
systemctl disable --now mergerfs-pool.service mergerfs-pool-watchdog.timer \
    snapraid-sync.timer snapraid-scrub.timer 2>/dev/null || true

# unmount the pool via wrapper if present
[ -x "${APP}/scripts/stop-pool.sh" ] && "${APP}/scripts/stop-pool.sh" || true

# remove units
for u in mergerfs-pool.service mergerfs-pool-watchdog.service mergerfs-pool-watchdog.timer \
         snapraid-sync.service snapraid-sync.timer snapraid-scrub.service snapraid-scrub.timer; do
    rm -f "${UNIT_DIR}/${u}"
done
systemctl daemon-reload

# unmerge + remove sysext image
rm -f "${EXT_DIR}/${NAME}.raw"
systemd-sysext refresh || true

cat <<EOF
Uninstalled binaries, units and sysext image.
PRESERVED: ${APP}/config (incl. snapraid.conf), logs, and ALL data + parity on disks.
To remove config too: rm -rf ${APP}
EOF
