#!/bin/sh
# Exercise install.sh / uninstall.sh as root in a throwaway container. systemctl and
# systemd-sysext are stubs; "merging" = unpacking the .raw's usr/ into the container.
# Usage (host): sh tests/install-in-container.sh build/out/mergerfs-snapraid_amd64.raw
set -eu
RAW="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm -i -v "$REPO:/src:ro" -v "$RAW:/img.raw:ro" debian:bookworm-slim sh -s <<'IN'
set -u
apt-get -qq update >/dev/null && apt-get -qq install -y squashfs-tools >/dev/null
FAILS=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
[ -c /dev/fuse ] || mknod /dev/fuse c 10 229
mkdir -p /stub && export PATH=/stub:$PATH
cat > /stub/systemctl <<'S'
#!/bin/sh
echo "systemctl $*" >> /calls
case "$1" in
  is-active) [ -f "/stub/active-$2" ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
esac
S
cat > /stub/systemd-sysext <<'S'
#!/bin/sh
case "$1" in
  refresh) if [ -f /var/lib/extensions/mergerfs-snapraid.raw ]; then
               unsquashfs -q -f -d / /var/lib/extensions/mergerfs-snapraid.raw usr >/dev/null
           else rm -rf /usr/lib/mergerfs-snapraid /usr/bin/snapraid; fi ;;
  status)  [ -f /var/lib/extensions/mergerfs-snapraid.raw ] && echo mergerfs-snapraid ;;
esac
S
chmod +x /stub/*

# a writable repo copy with build/out/ holding the image, units made +x on purpose
cp -a /src /repo && mkdir -p /repo/build/out && cp /img.raw /repo/build/out/mergerfs-snapraid_amd64.raw
( cd /repo/build/out && sha256sum mergerfs-snapraid_amd64.raw > SHA256SUMS )
chmod +x /repo/units/*

# --- 0) forum #21: AppData path hand-edited into the units, no /etc/default yet ---
L=/media/SSD-Storage/AppData/mergerfs-snapraid
leo_units() {
    mkdir -p /etc/systemd/system
    for u in /repo/units/*.service /repo/units/*.timer; do
        sed -e "s#/usr/lib/mergerfs-snapraid/#$L/scripts/#g" "$u" > "/etc/systemd/system/$(basename "$u")"
    done
    # his watchdog loop from post #21
    printf '[Service]\nType=oneshot\nExecStart=/bin/sh -c '"'"'for i in $(seq 1 60); do [ -x %s/scripts/start-pool.sh ] && break; sleep 1; done; exec systemctl start mergerfs-pool.service'"'"'\n' "$L" \
        > /etc/systemd/system/mergerfs-pool-watchdog.service
}
leo_units
mkdir -p $L/config $L/scripts
printf 'MOUNTPOINT=/DATA/Storage\nBRANCHES=/media/sdc:/media/sdd\nOPTS=defaults\n' > $L/config/pool.env
echo "# Leo's real snapraid.conf" > $L/config/snapraid.conf
sum_before="$(sha256sum $L/config/pool.env $L/config/snapraid.conf)"
/repo/install.sh > /out0 2>&1; rc=$?
[ "$rc" = 0 ] && ok "plain reinstall over hand-edited units exits 0" || { bad "rc=$rc"; cat /out0; }
grep -q "^APP_DIR='$L'\$" /etc/default/mergerfs-snapraid \
    && ok "APP_DIR adopted from the hand-edited units" || bad "APP_DIR not adopted: $(cat /etc/default/mergerfs-snapraid 2>&1)"
[ "$(sha256sum $L/config/pool.env $L/config/snapraid.conf)" = "$sum_before" ] \
    && ok "SSD pool.env + snapraid.conf untouched" || bad "SSD config changed"
[ ! -e /DATA/AppData/mergerfs-snapraid/config/pool.env ] \
    && ok "no stray example config created under /DATA/AppData" || bad "example config seeded under /DATA/AppData"
ls $L/units-backup-*/mergerfs-pool-watchdog.service >/dev/null 2>&1 \
    && grep -q "$L/scripts/start-pool.sh" $L/units-backup-*/mergerfs-pool-watchdog.service \
    && ok "hand-edited units backed up before overwrite" || bad "old units not backed up"

# SSD not mounted at install time: adopt nothing onto the bare mountpoint, refuse
rm -f /etc/default/mergerfs-snapraid; leo_units; mv /media/SSD-Storage /media/SSD-Storage.away
/repo/install.sh > /out0b 2>&1; rc=$?
[ "$rc" != 0 ] && [ ! -e /media/SSD-Storage ] && grep -q -- '--app-dir' /out0b \
    && ok "refuses when the adopted APP_DIR is not present (nothing created)" \
    || { bad "absent adopted APP_DIR: rc=$rc"; cat /out0b; }
mv /media/SSD-Storage.away /media/SSD-Storage

# units that disagree about the path: refuse instead of guessing
rm -f /etc/default/mergerfs-snapraid; leo_units
sed -i "s#$L/scripts/snapraid-sync.sh#/srv/other/scripts/snapraid-sync.sh#" /etc/systemd/system/snapraid-sync.service
/repo/install.sh > /out0c 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q -- '--app-dir' /out0c \
    && ok "refuses when units name different AppData paths" || { bad "conflicting units: rc=$rc"; cat /out0c; }

# reset for the remaining sections
rm -rf /etc/default/mergerfs-snapraid /media/SSD-Storage /etc/systemd/system/* /usr/lib/mergerfs-snapraid /DATA
: > /calls

# --- 1) upgrade over an OLD install: real (hand-edited) script copies in AppData ---
A=/DATA/AppData/mergerfs-snapraid
mkdir -p $A/scripts $A/config
echo "# Leo's edit" > $A/scripts/start-pool.sh
cp /repo/config/pool.env.example $A/config/pool.env
/repo/install.sh > /out1 2>&1; rc=$?
[ "$rc" = 0 ] && ok "install over old layout exits 0" || { bad "install rc=$rc"; cat /out1; }
[ "$(readlink $A/scripts/start-pool.sh)" = /usr/lib/mergerfs-snapraid/start-pool.sh ] \
    && ok "AppData script is now a symlink into the sysext" || bad "start-pool.sh not symlinked"
grep -q "Leo's edit" $A/scripts/.replaced-*/start-pool.sh 2>/dev/null \
    && ok "hand-edited copy preserved under scripts/.replaced-*" || bad "edited copy lost"
grep -q "^APP_DIR='$A'\$" /etc/default/mergerfs-snapraid && ok "defaults file records APP_DIR" || bad "defaults file wrong"
modes="$(stat -c %a /etc/systemd/system/mergerfs-pool.service /etc/systemd/system/mergerfs-pool-watchdog.timer | sort -u)"
[ "$modes" = 644 ] && ok "unit files installed 0644 although source was +x" || bad "unit modes: $modes"
grep -q '^ExecStart=/usr/lib/mergerfs-snapraid/start-pool.sh$' /etc/systemd/system/mergerfs-pool.service \
    && ok "installed pool unit execs from the sysext" || bad "pool unit ExecStart"
# timers must run right after install, not only after the next reboot (on .143 the
# snapraid timers sat enabled-but-inactive after a reinstall: no sync until a boot)
for t in snapraid-sync.timer snapraid-scrub.timer mergerfs-pool-watchdog.timer; do
    grep -q -E "^systemctl (enable --now|start) .*\b$t\b" /calls \
        && ok "install starts $t now" || bad "install only enables $t (inactive until reboot)"
done
grep -q -E '^systemctl (enable --now|start) .*mergerfs-pool\.service' /calls \
    && bad "install starts mergerfs-pool.service with an unedited config" \
    || ok "install does not start the pool itself"
# the symlinked script really runs and reads APP_DIR from /etc/default (needs config)
out="$(CONFIG_WAIT=1 $A/scripts/pool-status.sh 2>&1 | head -1)"
case "$out" in "pool: /DATA/Storage"*) ok "symlinked pool-status.sh runs: $out" ;; *) bad "pool-status: $out" ;; esac

# --- 2) --app-dir on a second disk, reinstall keeps it ---
/repo/install.sh --app-dir /media/SSD-Storage/AppData/mergerfs-snapraid > /out2 2>&1 \
    && grep -q "^APP_DIR='/media/SSD-Storage/AppData/mergerfs-snapraid'\$" /etc/default/mergerfs-snapraid \
    && [ -f /media/SSD-Storage/AppData/mergerfs-snapraid/config/pool.env ] \
    && ok "--app-dir records the new location and seeds its config" || { bad "--app-dir"; cat /out2; }
echo "CONFIG_WAIT=600" >> /etc/default/mergerfs-snapraid
echo "DELETE_THRESHOLD=5000" >> /etc/default/mergerfs-snapraid
/repo/install.sh > /out3 2>&1 && grep -q "SSD-Storage" /etc/default/mergerfs-snapraid \
    && ok "plain reinstall keeps the recorded APP_DIR" || bad "reinstall reset APP_DIR"
grep -q '^CONFIG_WAIT=600$' /etc/default/mergerfs-snapraid && grep -q '^DELETE_THRESHOLD=5000$' /etc/default/mergerfs-snapraid \
    && [ "$(grep -c '^APP_DIR=' /etc/default/mergerfs-snapraid)" = 1 ] \
    && ok "reinstall keeps other settings in /etc/default (one APP_DIR line)" \
    || { bad "settings in /etc/default lost:"; cat /etc/default/mergerfs-snapraid; }
[ -f /etc/systemd/system/mergerfs-snapraid-alert@.service ] \
    && ok "alert template unit installed" || bad "alert template unit missing"
/repo/install.sh --app-dir "/media/a b" > /out4 2>&1 && bad "path with space accepted" \
    || ok "--app-dir with a space is refused"

# --- 3) an image without the scripts must be refused ---
mkdir -p /oldimg/usr/bin && cp /usr/bin/true /oldimg/usr/bin/snapraid && cp /usr/bin/true /oldimg/usr/bin/mergerfs
mkdir -p /oldimg/usr/lib/extension-release.d && echo ID=_any > /oldimg/usr/lib/extension-release.d/extension-release.mergerfs-snapraid
cp -a /repo /repo-old && mksquashfs /oldimg /repo-old/build/out/mergerfs-snapraid_amd64.raw -comp gzip -noappend -quiet >/dev/null
( cd /repo-old/build/out && sha256sum mergerfs-snapraid_amd64.raw > SHA256SUMS )
rm -rf /usr/lib/mergerfs-snapraid
/repo-old/install.sh > /out5 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "predates the scripts-in-sysext" /out5 \
    && ok "install refuses an image without /usr/lib/mergerfs-snapraid" || { bad "old image accepted rc=$rc"; cat /out5; }

# review finding 4: after the merge /usr/bin/mergerfs must be the version the image
# ships — the ZimaOS base keeps a v1.5.4 there, so "it runs" proves nothing
rm -rf /fakeimg /repo-fake; unsquashfs -q -d /fakeimg /img.raw >/dev/null
printf '#!/bin/sh\necho "mergerfs v1.5.4"\n' > /fakeimg/usr/bin/mergerfs; chmod +x /fakeimg/usr/bin/mergerfs
cp -a /repo /repo-fake && rm -f /repo-fake/build/out/mergerfs-snapraid_amd64.raw
mksquashfs /fakeimg /repo-fake/build/out/mergerfs-snapraid_amd64.raw -comp gzip -all-root -noappend -quiet >/dev/null
( cd /repo-fake/build/out && sha256sum mergerfs-snapraid_amd64.raw > SHA256SUMS )
/repo-fake/install.sh > /out5v 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'v1.5.4' /out5v && grep -q 'expected' /out5v \
    && ok "install refuses when the merged mergerfs is not the shipped version" \
    || { bad "wrong merged mergerfs version accepted rc=$rc"; cat /out5v; }
[ -f /usr/lib/mergerfs-snapraid/VERSIONS ] || unsquashfs -q -f -d / /img.raw usr >/dev/null
grep -q '^MERGERFS_VERSION=[0-9]' /usr/lib/mergerfs-snapraid/VERSIONS 2>/dev/null \
    && ok "image carries usr/lib/mergerfs-snapraid/VERSIONS" || bad "VERSIONS file missing in image"

# --- 4) uninstall: symlinks gone, config + defaults kept ---
/repo/install.sh > /dev/null 2>&1
S=/media/SSD-Storage/AppData/mergerfs-snapraid
/repo/uninstall.sh > /out6 2>&1
[ ! -e $S/scripts/start-pool.sh ] && [ ! -L $S/scripts/start-pool.sh ] && ok "uninstall removes the script symlinks" || bad "symlinks left"
[ -f $S/config/pool.env ] && [ -f /etc/default/mergerfs-snapraid ] && ok "uninstall keeps config + defaults" || bad "config lost"
[ ! -e /etc/systemd/system/mergerfs-pool.service ] && [ ! -e /etc/systemd/system/mergerfs-snapraid-alert@.service ] \
    && ok "uninstall removes units (incl. alert template)" || bad "units left: $(ls /etc/systemd/system)"

# --- 5) replace-disk: a FAILED recovery must not re-arm the sync (review finding 3) ---
rm -rf /etc/default/mergerfs-snapraid /DATA/AppData; : > /calls
RA=/DATA/AppData/mergerfs-snapraid
mkdir -p $RA/config /rd
cp /repo/scripts/*.sh /rd/
# d1 must be a real mountpoint: /dev/shm is one inside the container (tmpfs)
printf 'parity /p/snapraid.parity\ncontent /c/snapraid.content\ndata d1 /dev/shm\n' > $RA/config/snapraid.conf
cat > /rd/snapraid-stub <<'S'
#!/bin/sh
echo "SNAPRAID $*" >> /calls
case "$*" in *" fix"*) [ -f /fix-fails ] && exit 1 ;; esac
case "$*" in *diff*) printf "       1 equal\n       0 removed\n"; exit 0 ;; esac
exit 0
S
chmod +x /rd/snapraid-stub
printf "APP_DIR='%s'\nSNAPRAID_BIN=/rd/snapraid-stub\nCONFIG_WAIT=1\n" $RA > /etc/default/mergerfs-snapraid
M=$RA/RECOVERY-IN-PROGRESS

touch /fix-fails
echo d1 | /rd/replace-disk.sh d1 > /out5a 2>&1; rc=$?
[ "$rc" != 0 ] && ok "failed fix: replace-disk exits $rc" || bad "failed fix exited 0"
[ -f $M ] && ok "failed fix: RECOVERY-IN-PROGRESS marker stays" || bad "marker missing after failed fix"
grep -q '^systemctl start .*snapraid-sync.timer' /calls \
    && bad "failed fix re-armed the sync timer" || ok "failed fix leaves the sync/scrub timers stopped"
: > /calls
/rd/snapraid-sync.sh > /out5b 2>&1; rc=$?
[ "$rc" != 0 ] && ! grep -q '^SNAPRAID' /calls && grep -q 'RECOVERY-IN-PROGRESS' /out5b \
    && ok "sync refuses while the recovery marker exists (snapraid not run)" || { bad "sync ran during recovery rc=$rc"; cat /out5b; }
/rd/snapraid-scrub.sh > /out5c 2>&1; rc=$?
[ "$rc" != 0 ] && ! grep -q '^SNAPRAID' /calls \
    && ok "scrub refuses while the recovery marker exists" || bad "scrub ran during recovery rc=$rc"

rm -f /fix-fails; : > /calls
echo d1 | /rd/replace-disk.sh d1 > /out5d 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -f $M ] && grep -q '^systemctl start .*snapraid-sync.timer' /calls \
    && ok "successful retry: exit 0, marker removed, timers re-armed" || { bad "successful recovery rc=$rc"; cat /out5d; }

: > /calls; touch /stub/active-snapraid-sync.service
echo d1 | /rd/replace-disk.sh d1 > /out5e 2>&1; rc=$?
[ "$rc" != 0 ] && ! grep -q 'SNAPRAID .* fix' /calls && [ ! -f $M ] \
    && ok "refuses to start while a sync is running" || { bad "started during a running sync rc=$rc"; cat /out5e; }
rm -f /stub/active-snapraid-sync.service

# --- 5b) replace-disk: only a BLANK disk, and not one of the other configured disks ---
# README: "refuses to proceed on a mismatch"; header step 3: "right FS, empty".
: > /calls; rm -f $M; touch /dev/shm/leftover.bin
echo d1 | /rd/replace-disk.sh d1 > /out5f 2>&1; rc=$?
[ "$rc" != 0 ] && ! grep -q 'SNAPRAID .* fix' /calls && [ ! -f $M ] && grep -q 'not empty' /out5f \
    && ok "refuses a replacement that is not empty (no fix, no marker)" || { bad "non-empty replacement accepted rc=$rc"; cat /out5f; }
: > /calls; touch $M
echo d1 | /rd/replace-disk.sh d1 > /out5g 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'SNAPRAID .* fix' /calls \
    && ok "a retry (marker present) may continue on a partly rebuilt disk" || { bad "retry refused rc=$rc"; cat /out5g; }
rm -f /dev/shm/leftover.bin $M
mkdir -p /dev/shm/other
printf 'parity /p/snapraid.parity\ncontent /c/snapraid.content\ndata d1 /dev/shm\ndata d2 /dev/shm/other\n' > $RA/config/snapraid.conf
: > /calls
echo d1 | /rd/replace-disk.sh d1 > /out5h 2>&1; rc=$?
[ "$rc" != 0 ] && ! grep -q 'SNAPRAID .* fix' /calls && grep -q 'same device as d2' /out5h \
    && ok "refuses when the path sits on the same device as another configured disk" || { bad "other disk's device accepted rc=$rc"; cat /out5h; }
rmdir /dev/shm/other

echo; [ "$FAILS" = 0 ] && echo "all container checks passed" || echo "$FAILS container check(s) FAILED"
[ "$FAILS" = 0 ]
IN
