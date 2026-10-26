#!/bin/sh
# Host-free tests for the pool/sync scripts and the unit files. Runs anywhere with a
# POSIX sh (no root, no FUSE, no ZimaOS): mergerfs and snapraid are replaced by stubs
# via the same /etc/default/mergerfs-snapraid mechanism the installer uses
# (MSR_DEFAULTS points the scripts at a test copy of that file).
#
# Usage: sh tests/run.sh        exit 0 = all passed
set -u
umask 022    # as root's units: the folder check refuses a group-writable APP_DIR
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
# the folder check trusts root; here the test user owns the fake world
APPDATA_GUARD_UID="$(id -u)"; export APPDATA_GUARD_UID
trap 'rm -rf "$WORK"' EXIT
FAILS=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }

# A fresh fake world per test: APP_DIR, two branch dirs, stub binaries, defaults file.
setup() {
    T="$WORK/$1"
    mkdir -p "$T/bin" "$T/media/sda" "$T/media/sdb" "$T/pool"
    touch "$T/media/sda/f" "$T/media/sdb/f"          # both branches "ready" (non-empty)
    printf '#!/bin/sh\necho "MERGERFS $*" >> "%s/calls"\n' "$T" > "$T/bin/mergerfs"
    printf '#!/bin/sh\necho "SNAPRAID $*" >> "%s/calls"\nexit 0\n' "$T" > "$T/bin/snapraid"
    chmod +x "$T/bin/mergerfs" "$T/bin/snapraid"
    APP="$T/appdata/mergerfs-snapraid"
    cat > "$T/defaults" <<EOF
APP_DIR='$APP'
MERGERFS_BIN='$T/bin/mergerfs'
SNAPRAID_BIN='$T/bin/snapraid'
CONFIG_WAIT=4
EOF
    export MSR_DEFAULTS="$T/defaults"
}

write_pool_cfg() {
    mkdir -p "$APP/config"
    printf 'MOUNTPOINT=%s/pool\nBRANCHES=%s/media/sda:%s/media/sdb\nOPTS=defaults\n' \
        "$T" "$T" "$T" > "$APP/config/pool.env"
}

# --- forum #21: AppData on a disk that mounts AFTER the pool unit starts ----------
setup late_config
( sleep 2; write_pool_cfg ) &
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
wait
if [ "$rc" = 0 ] && grep -q "^MERGERFS -o defaults $T/media/sda:$T/media/sdb $T/pool\$" "$T/calls" 2>/dev/null; then
    pass "start-pool waits for a late pool config, then mounts (APP_DIR from defaults file)"
else
    fail "start-pool waits for a late pool config (rc=$rc): $out"
fi

setup config_never
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$APP" && [ ! -e "$T/calls" ]; then
    pass "start-pool fails loudly naming APP_DIR when the config never appears"
else
    fail "start-pool must fail naming $APP when the config never appears (rc=$rc): $out"
fi

# A missing APP_DIR at sync time must not create logs/ on the bare mountpoint dir
# (that would write onto the root fs underneath the not-yet-mounted disk).
for job in snapraid-sync snapraid-scrub; do
    setup "missing_conf_$job"
    out="$(sh "$REPO/scripts/$job.sh" 2>&1)"; rc=$?
    if [ "$rc" != 0 ] && [ ! -e "$APP" ] && [ ! -e "$T/calls" ]; then
        pass "$job refuses (rc=$rc) and writes nothing when snapraid.conf is absent"
    else
        fail "$job with absent APP_DIR: rc=$rc, APP_DIR created=$([ -e "$APP" ] && echo yes || echo no): $out"
    fi
done

# --- unedited example configs must never touch real disks -------------------------
# install.sh seeds the examples and now starts the timers at once; the examples name
# /media/sda + /media/sdb, which are real disks on many ZimaOS boxes.
example_world() {
    setup "$1"
    mkdir -p "$APP/config" "$T/examples"
    cp "$REPO/config/pool.env.example" "$T/examples/"
    cp "$REPO/config/snapraid.conf.example" "$T/examples/"
    echo "EXAMPLES_DIR='$T/examples'" >> "$T/defaults"
}
example_world example_pool
cp "$REPO/config/pool.env.example" "$APP/config/pool.env"
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && [ ! -e "$T/calls" ] && printf '%s' "$out" | grep -q 'unedited example'; then
    pass "start-pool refuses an unedited example pool.env"
else
    fail "start-pool with example pool.env: rc=$rc calls=$(cat "$T/calls" 2>/dev/null): $out"
fi
for job in snapraid-sync snapraid-scrub; do
    example_world "example_$job"
    cp "$REPO/config/snapraid.conf.example" "$APP/config/snapraid.conf"
    out="$(sh "$REPO/scripts/$job.sh" 2>&1)"; rc=$?
    log="$(cat "$APP"/logs/* 2>/dev/null)"
    if [ "$rc" != 0 ] && [ ! -e "$T/calls" ] && printf '%s%s' "$out" "$log" | grep -q 'unedited example'; then
        pass "$job refuses an unedited example snapraid.conf (snapraid not called)"
    else
        fail "$job with example snapraid.conf: rc=$rc calls=$(cat "$T/calls" 2>/dev/null): $out $log"
    fi
    # an edited config still runs (positive control)
    example_world "edited_$job"
    { cat "$REPO/config/snapraid.conf.example"; echo "# edited"; } > "$APP/config/snapraid.conf"
    printf '#!/bin/sh\necho "SNAPRAID $*" >> "%s/calls"\ncase "$*" in *diff*) printf "       1 equal\\n       0 removed\\n"; exit 0;; esac\nexit 0\n' "$T" > "$T/bin/snapraid"
    sh "$REPO/scripts/$job.sh" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 0 ] && grep -q '^SNAPRAID' "$T/calls" 2>/dev/null; then
        pass "$job runs snapraid once snapraid.conf is edited"
    else
        fail "$job with edited snapraid.conf: rc=$rc calls=$(cat "$T/calls" 2>/dev/null)"
    fi
done

# --- review finding 1: a failing snapraid run must fail the unit ------------------
for job in snapraid-sync snapraid-scrub; do
    setup "fails_$job"
    mkdir -p "$APP/config"; echo "# edited test config" > "$APP/config/snapraid.conf"
    printf '#!/bin/sh\ncase "$*" in *diff*) printf "       1 equal\\n       0 removed\\n"; exit 2;; esac\necho "Error: disk d2 read error"; exit 1\n' > "$T/bin/snapraid"
    sh "$REPO/scripts/$job.sh" >/dev/null 2>&1; rc=$?
    [ "$rc" != 0 ] && pass "$job exits non-zero when snapraid fails (rc=$rc)" \
        || fail "$job reports success although snapraid exited 1"
done

# --- review finding 2: never mount over an empty, unmounted branch -----------------
setup empty_branch
write_pool_cfg
rm -f "$T/media/sdb/f"                       # sdb: empty dir, not a mountpoint
echo "BRANCH_WAIT=2" >> "$APP/config/pool.env"
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && [ ! -e "$T/calls" ]; then
    pass "start-pool refuses to mount over an empty, unmounted branch"
else
    fail "start-pool mounted over an empty branch (rc=$rc): $out"
fi
setup empty_branch_marker                    # .mergerfs.branch = "this folder IS the branch"
write_pool_cfg
rm -f "$T/media/sdb/f"; touch "$T/media/sdb/.mergerfs.branch"
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^MERGERFS' "$T/calls" 2>/dev/null \
    && pass "start-pool accepts an empty branch marked with .mergerfs.branch" \
    || fail "marked empty branch rejected (rc=$rc): $out"
setup empty_branch_allowed
write_pool_cfg
rm -f "$T/media/sdb/f"; printf 'BRANCH_WAIT=2\nALLOW_EMPTY_BRANCH=1\n' >> "$APP/config/pool.env"
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^MERGERFS' "$T/calls" 2>/dev/null \
    && pass "ALLOW_EMPTY_BRANCH=1 keeps the old proceed-anyway behaviour" \
    || fail "ALLOW_EMPTY_BRANCH=1 ignored (rc=$rc): $out"

# --- trapexit: branches-mount-timeout-fail (verified on .143: rc=1, no mount) ------
grep -q '^OPTS=.*branches-mount-timeout-fail=true' "$REPO/config/pool.env.example" \
    && pass "example OPTS enable branches-mount-timeout-fail" \
    || fail "example OPTS lack branches-mount-timeout-fail=true"

setup fail_hint                              # branches + mountpoint all on one fs (tmp)
write_pool_cfg
sed -i 's/^OPTS=defaults$/OPTS=defaults,branches-mount-timeout-fail=true/' "$APP/config/pool.env"
touch "$T/media/sda/.mergerfs.branch"        # sda marked, sdb not
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
if printf '%s' "$out" | grep -q "NOTE: $T/media/sdb is on the same filesystem" \
   && ! printf '%s' "$out" | grep -q "NOTE: $T/media/sda " && [ "$rc" = 0 ]; then
    pass "start-pool names the unmarked same-fs branch that mergerfs -fail would reject"
else
    fail "missing/wrong -fail hint (rc=$rc): $out"
fi

# --- mergerfs-tools: balance/consolidate break hardlinks + dir mtimes (PR #153, #157)
grep -q 'hardlink' "$REPO/scripts/mergerfs-tool.sh" && grep -q 'mtime' "$REPO/scripts/mergerfs-tool.sh" \
    && pass "mergerfs-tool.sh warns about hardlinks and directory mtimes" \
    || fail "mergerfs-tool.sh has no hardlink/mtime warning"

# --- forum #20: deletion guard settable + one-time release ------------------------
deletes_world() {
    setup "$1"
    mkdir -p "$APP/config"; echo "# edited test config" > "$APP/config/snapraid.conf"
    printf '#!/bin/sh\necho "SNAPRAID $*" >> "%s/calls"\ncase "$*" in *diff*) printf "      10 equal\\n    8000 removed\\n"; exit 2;; esac\nexit 0\n' "$T" > "$T/bin/snapraid"
}
synced() { grep -q 'SNAPRAID .* sync$' "$T/calls" 2>/dev/null; }
deletes_world del_default
sh "$REPO/scripts/snapraid-sync.sh" >/dev/null 2>&1; rc=$?
log="$(cat "$APP"/logs/sync-* 2>/dev/null)"
if [ "$rc" != 0 ] && ! synced && printf '%s' "$log" | grep -q -- '--allow-deletes 8000'; then
    pass "8000 deletions abort the sync and the log names the one-time release command"
else
    fail "default guard: rc=$rc synced=$(synced && echo yes || echo no) log: $log"
fi
deletes_world del_setting
echo "DELETE_THRESHOLD=10000" >> "$T/defaults"
sh "$REPO/scripts/snapraid-sync.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && synced && pass "DELETE_THRESHOLD in /etc/default raises the guard" \
    || fail "DELETE_THRESHOLD from defaults file ignored (rc=$rc)"
deletes_world del_once_ok
sh "$REPO/scripts/snapraid-sync.sh" --allow-deletes 8000 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && synced && pass "--allow-deletes 8000 releases exactly this run" \
    || fail "--allow-deletes 8000 did not sync (rc=$rc)"
deletes_world del_once_low
sh "$REPO/scripts/snapraid-sync.sh" --allow-deletes 7999 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ! synced && pass "--allow-deletes below the real count still aborts" \
    || fail "--allow-deletes 7999 synced 8000 deletions (rc=$rc)"

# --- failure alert (OnFailure=) ----------------------------------------------------
setup alert
mkdir -p "$APP/logs"
printf '#!/bin/sh\necho "journal line for $*"\n' > "$T/bin/journalctl"; chmod +x "$T/bin/journalctl"
echo "NOTIFY_CMD='echo \"\$ALERT_UNIT|\$ALERT_FILE\" > $T/notified'" >> "$T/defaults"
PATH="$T/bin:$PATH" sh "$REPO/scripts/alert.sh" snapraid-sync.service >/dev/null 2>&1; rc=$?
f="$(ls "$APP"/logs/ALERT-snapraid-sync.service-* 2>/dev/null | head -1)"
if [ "$rc" = 0 ] && [ -n "$f" ] && grep -q 'journal line for -u snapraid-sync.service' "$f" \
   && grep -q "^snapraid-sync.service|$f\$" "$T/notified" 2>/dev/null; then
    pass "alert.sh writes ALERT file with the unit's journal and runs NOTIFY_CMD"
else
    fail "alert.sh: rc=$rc file=$f notified=$(cat "$T/notified" 2>/dev/null)"
fi
# A unit that "failed" only because its config is still the shipped example is not set up
# yet — no alert (measured 2026-10-19 on a ZimaBoard 2: a fresh install wrote
# ALERT-mergerfs-pool.service-… at once, the watchdog timer had started the pool).
setup alert_unconfigured
mkdir -p "$APP/logs" "$APP/config" "$T/ex"
printf '#!/bin/sh\necho "journal line for $*"\n' > "$T/bin/journalctl"; chmod +x "$T/bin/journalctl"
echo "NOTIFY_CMD='echo \"\$ALERT_UNIT\" >> $T/notified'" >> "$T/defaults"
printf 'MOUNTPOINT="/DATA/Storage"\nBRANCHES="/media/sda:/media/sdb"\n' > "$T/ex/pool.env.example"
printf 'parity /media/parity1/snapraid.parity\ndata d1 /media/sda\n' > "$T/ex/snapraid.conf.example"
cp "$T/ex/pool.env.example" "$APP/config/pool.env"; cp "$T/ex/snapraid.conf.example" "$APP/config/snapraid.conf"
for u in mergerfs-pool.service snapraid-sync.service snapraid-scrub.service; do
    out="$(EXAMPLES_DIR="$T/ex" PATH="$T/bin:$PATH" sh "$REPO/scripts/alert.sh" "$u" 2>&1)"; rc=$?
    if [ "$rc" = 0 ] && ! ls "$APP"/logs/ALERT-"$u"-* >/dev/null 2>&1 && ! grep -q "^$u\$" "$T/notified" 2>/dev/null \
       && printf '%s' "$out" | grep -q 'not configured yet'; then
        pass "alert.sh stays quiet for $u while its config is the unedited example"
    else
        fail "alert.sh alerted for unconfigured $u (rc=$rc): $out"
    fi
done
echo 'BRANCHES="/mnt/a:/mnt/b"' >> "$APP/config/pool.env"
EXAMPLES_DIR="$T/ex" PATH="$T/bin:$PATH" sh "$REPO/scripts/alert.sh" mergerfs-pool.service >/dev/null 2>&1
ls "$APP"/logs/ALERT-mergerfs-pool.service-* >/dev/null 2>&1 && grep -q '^mergerfs-pool.service$' "$T/notified" \
    && pass "alert.sh alerts again once its config is edited" || fail "no alert for an edited pool config"
for u in mergerfs-pool.service snapraid-sync.service snapraid-scrub.service; do
    grep -q '^OnFailure=mergerfs-snapraid-alert@%n.service$' "$REPO/units/$u" \
        && pass "$u triggers the alert on failure" || fail "$u has no OnFailure alert"
done

# --- no hard-coded AppData path outside the single per-script default --------------
hits="$(grep -rn '/DATA/AppData/mergerfs-snapraid' "$REPO/scripts" "$REPO/units" \
          "$REPO/install.sh" "$REPO/uninstall.sh" \
        | grep -v -E ':(APP_DIR|DEFAULT_APP_DIR)=/DATA/AppData/mergerfs-snapraid$' || true)"
if [ -z "$hits" ]; then
    pass "AppData path only appears as the documented default"
else
    fail "hard-coded AppData path:"; printf '%s\n' "$hits"
fi

# --- units must not exec anything from AppData (it may sit on a late disk) ---------
bad=""
for u in "$REPO"/units/*.service; do
    for p in $(sed -n 's/^Exec\(Start\|Stop\)=\(\/[^ ]*\).*/\2/p' "$u"); do
        case "$p" in
            /bin/sh) ;;
            /usr/lib/mergerfs-snapraid/*)
                [ -f "$REPO/scripts/${p##*/}" ] || bad="$bad $(basename "$u"):$p(no such script)" ;;
            *) bad="$bad $(basename "$u"):$p" ;;
        esac
    done
done
if [ -z "$bad" ]; then
    pass "every unit Exec* path is a sysext script under /usr/lib/mergerfs-snapraid"
else
    fail "unit Exec* outside the sysext:$bad"
fi

# --- forum #21 journal: "Configuration file ... is marked executable" --------------
# Static check (install.sh needs root + systemd): the unit copy must end in 0644.
if grep -q 'chmod 0644 "\$UNIT_DIR/\$(basename "\$u")"' "$REPO/install.sh"; then
    pass "install.sh normalises unit file mode to 0644 (static check)"
else
    fail "install.sh does not force unit files to 0644"
fi

# --- /DATA/AppData is 0777 without the sticky bit on ZimaOS 1.8 (KB §79.11) -----------
# root sources pool.env from APP_DIR: a folder that is a symlink (or not root's) is refused
setup appdata_symlink
write_pool_cfg
mv "$APP" "$T/planted" && ln -s "$T/planted" "$APP"
out="$(sh "$REPO/scripts/start-pool.sh" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "ist ein Symlink" && [ ! -e "$T/calls" ]; then
    pass "start-pool refuses an APP_DIR that is a symlink, before reading pool.env"
else
    fail "start-pool must refuse a symlinked APP_DIR (rc=$rc): $out"
fi
for s in mergerfs-tool.sh pool-status.sh replace-disk.sh snapraid-scrub.sh snapraid-sync.sh stop-pool.sh alert.sh start-pool.sh; do
    if grep -q 'appdata-guard.sh}" --no-create "$APP_DIR"' "$REPO/scripts/$s"; then
        pass "$s checks APP_DIR (appdata-guard.sh --no-create)"
    else
        fail "$s reads APP_DIR without the folder check"
    fi
done
MODKIT="$REPO/../../lintux-modkit/sysext/appdata-guard.sh"
if [ ! -f "$MODKIT" ]; then
    pass "appdata-guard.sh copy (lintux-modkit not next to the repo, not compared)"
elif cmp -s "$MODKIT" "$REPO/scripts/appdata-guard.sh"; then
    pass "scripts/appdata-guard.sh is lintux-modkit's"
else
    fail "scripts/appdata-guard.sh differs from $MODKIT — copy it again"
fi

echo
if [ "$FAILS" = 0 ]; then echo "all tests passed"; else echo "$FAILS test(s) FAILED"; fi
[ "$FAILS" = 0 ]
