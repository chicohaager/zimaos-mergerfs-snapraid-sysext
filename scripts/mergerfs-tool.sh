#!/bin/sh
# SnapRAID-aware one-shot runner for trapexit/mergerfs-tools on ZimaOS.
#
# WHY a container: ZimaOS has no native Python; these tools are pure-Python3 (+rsync).
#   The storage runtime stays native (the sysext) — only this maintenance step uses
#   Docker. The image is built on first use (build/Dockerfile.mergerfs-tools, pinned
#   to an upstream commit).
# WHY a wrapper: balance/consolidate/dedup/dup physically MOVE data between disks,
#   which makes SnapRAID parity STALE until the next `snapraid sync`. From SnapRAID's
#   view a moved file is "removed" from one disk and "added" to another. With
#   --quiesce we stop the sync/scrub timers, run the tool, then sync + re-arm.
#
# Usage:
#   mergerfs-tool.sh status                          native overview (no Docker)
#   mergerfs-tool.sh [--quiesce] balance [opts]      equalize fullness across disks
#   mergerfs-tool.sh [--quiesce] consolidate <dir> [opts]   (-e to execute)
#   mergerfs-tool.sh [--quiesce] dedup <dir> [opts]         (-e to execute)
#   mergerfs-tool.sh [--quiesce] dup <dir> [opts]           (-e to execute)
#   mergerfs-tool.sh fsck <dir> [opts]               audit perms/ownership (-f to fix)
#   mergerfs-tool.sh ctl ...                          runtime branch/option control
#   mergerfs-tool.sh mktrash                          create per-branch .Trash dirs
#
# Without --quiesce on a data-moving op you MUST run scripts/snapraid-sync.sh yourself
# afterwards, or parity will not reflect the moved files. Confidence: NOT yet
# hardware-tested (the runner is new) — dry-run first and verify a sync before trust.
set -eu

IMAGE="${MFT_IMAGE:-mergerfs-tools:local}"
ENV_FILE=/DATA/AppData/mergerfs-snapraid/config/pool.env
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# Dockerfile lives in build/ in the repo; install.sh also drops a copy next to the
# scripts. Resolve whichever exists (dev checkout vs installed /DATA layout).
DOCKERFILE=""
for cand in \
    "${SELF_DIR}/../build/Dockerfile.mergerfs-tools" \
    "${SELF_DIR}/Dockerfile.mergerfs-tools"; do
    [ -f "$cand" ] && { DOCKERFILE="$cand"; break; }
done
# ':-'-trap (KB §2.3): default only when UNSET (ZimaOS host); respect an explicit
# empty DOCKER_CONFIG (a CI/non-ZimaOS runner that wants its own ~/.docker).
export DOCKER_CONFIG="${DOCKER_CONFIG-/DATA/.docker}"

[ "$(id -u)" = "0" ] || { echo "must run as root (Docker + systemctl)"; exit 1; }

# --- parse leading wrapper flags -------------------------------------------------
QUIESCE=0; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --quiesce) QUIESCE=1; shift ;;
        -y|--yes)  YES=1; shift ;;
        --)        shift; break ;;
        -*)        echo "unknown wrapper flag: $1"; exit 1 ;;
        *)         break ;;
    esac
done
TOOL="${1:-}"; [ -n "$TOOL" ] || { sed -n '11,21p' "$0"; exit 1; }
shift || true

# --- status: native fast path, no Docker -----------------------------------------
if [ "$TOOL" = "status" ]; then
    exec "${SELF_DIR}/pool-status.sh"
fi

case "$TOOL" in
    balance|consolidate|dedup|dup|fsck|ctl|mktrash) ;;
    *) echo "unknown tool '$TOOL' (balance|consolidate|dedup|dup|fsck|ctl|mktrash|status)"; exit 1 ;;
esac

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${MOUNTPOINT:?set MOUNTPOINT in pool.env}"
: "${BRANCHES:?set BRANCHES in pool.env}"
command -v docker >/dev/null 2>&1 || { echo "docker not found (this runner needs Docker)"; exit 1; }
mountpoint -q "$MOUNTPOINT" || { echo "pool not mounted at $MOUNTPOINT — run start-pool.sh first"; exit 1; }

# --- does this invocation MOVE/CHANGE data? (=> parity goes stale) ---------------
MUTATES=0
case "$TOOL" in
    balance) MUTATES=1 ;;                                 # balance has NO dry-run
    consolidate|dedup|dup)                                # print-only unless -e/--execute
        for a in "$@"; do case "$a" in -e|--execute) MUTATES=1 ;; esac; done ;;
    fsck)
        for a in "$@"; do case "$a" in -f|--fix) MUTATES=1 ;; esac; done ;;
esac

# balance always writes immediately: refuse without a parity plan.
if [ "$TOOL" = "balance" ] && [ "$QUIESCE" = 0 ] && [ "$YES" = 0 ]; then
    echo "REFUSE: 'balance' moves files immediately and has no dry-run."
    echo "  Re-run with --quiesce  (stop timers -> balance -> snapraid sync -> re-arm),"
    echo "  or with --yes if you will run scripts/snapraid-sync.sh yourself afterwards."
    exit 1
fi

# --- build image on first use (no local context needed; ADD fetches everything) --
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    [ -f "$DOCKERFILE" ] || { echo "missing $DOCKERFILE"; exit 1; }
    echo "building $IMAGE (first use) ..."
    docker build -t "$IMAGE" - < "$DOCKERFILE"
fi

# balance with no explicit path -> target the whole pool.
if [ "$TOOL" = "balance" ]; then
    set -- "$@" "$MOUNTPOINT"
fi

# Bind-mounts: the pool (for the user.mergerfs.* control xattrs the tools read via
# libc lgetxattr) PLUS each configured branch at its own path (where files physically
# live), so the tools' statvfs/rsync hit the same locations as the host. Branches may
# be under /media (ZimaOS data disks) or anywhere else (e.g. /DATA/...). Assumes branch
# paths contain no spaces (true for /media/sdX and typical mounts).
MOUNTS="-v $MOUNTPOINT:$MOUNTPOINT"
for raw in $(echo "$BRANCHES" | tr ':' ' '); do
    b="${raw%%=*}"                          # strip mergerfs =RW/=RO/=NC mode suffix
    case "$b" in *'*'*) continue ;; esac    # can't bind-mount a glob branch
    MOUNTS="$MOUNTS -v $b:$b"
done

run_tool() {
    # shellcheck disable=SC2086  # $MOUNTS must word-split into separate -v flags
    docker run --rm -i $MOUNTS "$IMAGE" "mergerfs.$TOOL" "$@"
}

if [ "$MUTATES" = 1 ] && [ "$QUIESCE" = 1 ]; then
    restore_timers() {
        echo "--- re-arming snapraid timers ---"
        systemctl start snapraid-sync.timer snapraid-scrub.timer 2>/dev/null || true
    }
    trap 'rc=$?; [ "$rc" = 0 ] || echo "!!! mergerfs.'"$TOOL"' exited $rc — re-arming timers; parity may be PARTIAL, inspect before trusting it"; restore_timers; exit $rc' EXIT

    echo "--- stopping snapraid timers (no scheduled sync/scrub during the move) ---"
    systemctl stop snapraid-sync.timer snapraid-scrub.timer 2>/dev/null || true

    echo "--- running mergerfs.$TOOL ---"
    run_tool "$@"

    # Re-sync parity. A balance legitimately "removes" files from one disk and "adds"
    # them to another, so the default mass-deletion guard (200) would WRONGLY abort.
    # Raise it for this controlled, attended, quiesced sync — but keep the rest of the
    # guard (the fail-closed disk-missing / no-summary checks still protect us).
    echo "--- snapraid sync (re-align parity to the moved files) ---"
    DELETE_THRESHOLD="${POST_MOVE_THRESHOLD:-1000000}" "${SELF_DIR}/snapraid-sync.sh" \
        && echo "sync OK (log under /DATA/AppData/mergerfs-snapraid/logs)" \
        || echo "!!! snapraid-sync.sh reported a problem — check the latest log before trusting parity"
    echo "timers will be re-armed on exit."
else
    run_tool "$@"
    if [ "$MUTATES" = 1 ]; then
        echo
        echo "NOTE: files were moved/changed -> SnapRAID parity is now STALE."
        echo "      Run:  ${SELF_DIR}/snapraid-sync.sh    (or re-run with --quiesce next time)"
    fi
fi
