#!/bin/sh
# Uninstall the mergerfs+snapraid sysext. PRESERVES all data, config and parity.
# Does NOT delete anything under the data disks or the config dir (APP_DIR).
set -u

NAME="mergerfs-snapraid"
DEFAULTS="/etc/default/${NAME}"
LIBEXEC="/usr/lib/${NAME}"
APP_DIR=/DATA/AppData/mergerfs-snapraid
# shellcheck disable=SC1090
[ -f "$DEFAULTS" ] && . "$DEFAULTS"
APP="$APP_DIR"
EXT_DIR="/var/lib/extensions"
UNIT_DIR="/etc/systemd/system"

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }

# stop + disable
systemctl disable --now mergerfs-pool.service mergerfs-pool-watchdog.timer \
    snapraid-sync.timer snapraid-scrub.timer 2>/dev/null || true

# unmount the pool via wrapper if present
if [ -x "${LIBEXEC}/stop-pool.sh" ]; then "${LIBEXEC}/stop-pool.sh" || true; fi

# drop the symlinks install.sh placed in ${APP}/scripts (they would dangle once the
# sysext is gone); real files there are left alone
for l in "${APP}/scripts/"*; do
    [ -L "$l" ] || continue
    case "$(readlink "$l")" in "${LIBEXEC}/"*) rm -f "$l" ;; esac
done

# remove units
for u in mergerfs-pool.service mergerfs-pool-watchdog.service mergerfs-pool-watchdog.timer \
         snapraid-sync.service snapraid-sync.timer snapraid-scrub.service snapraid-scrub.timer \
         mergerfs-snapraid-alert@.service; do
    rm -f "${UNIT_DIR}/${u}"
done
systemctl daemon-reload

# unmerge + remove sysext image
rm -f "${EXT_DIR}/${NAME}.raw"
systemd-sysext refresh || true

cat <<EOF
Uninstalled binaries, units and sysext image.
PRESERVED: ${APP}/config (incl. snapraid.conf), logs, and ALL data + parity on disks,
           plus ${DEFAULTS} (remembers APP_DIR for a reinstall).
To remove config too: rm -rf ${APP} ${DEFAULTS}
EOF
