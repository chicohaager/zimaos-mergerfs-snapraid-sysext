#!/bin/sh
# Native (no Docker, no Python) read-only pool overview: per-branch fullness, the
# spread between the fullest and emptiest disk, pool mount state + mergerfs version.
# Answers the question that should precede any balance: "is the pool unbalanced
# enough to bother?". Pure busybox/POSIX — runs straight on the ZimaOS host.
set -eu
ENV_FILE=/DATA/AppData/mergerfs-snapraid/config/pool.env
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${MOUNTPOINT:?set MOUNTPOINT in pool.env}"
: "${BRANCHES:?set BRANCHES in pool.env}"

if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
    ver="$(/usr/bin/mergerfs --version 2>/dev/null | head -1 | awk '{print $NF}')"
    echo "pool: $MOUNTPOINT  (mounted, mergerfs ${ver:-?})"
else
    echo "pool: $MOUNTPOINT  (NOT mounted — start-pool.sh first)"
fi
echo

printf '%-26s %8s %8s %8s %6s\n' BRANCH SIZE USED AVAIL USE%
# BRANCHES is colon-separated; strip mergerfs =RW/=RO/=NC mode suffixes, skip globs.
echo "$BRANCHES" | tr ':' '\n' | while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    b="${raw%%=*}"
    case "$b" in *'*'*) printf '%-26s %8s\n' "$b" "(glob)"; continue;; esac
    if [ -d "$b" ]; then
        df -h -P "$b" 2>/dev/null | awk -v p="$b" 'NR==2{printf "%-26s %8s %8s %8s %6s\n", p,$2,$3,$4,$5}'
    else
        printf '%-26s %8s\n' "$b" "MISSING"
    fi
done

# Fullness spread. A POSIX while-subshell can't export vars to the parent, so feed
# all branch use%% into a single awk and compute min/max there.
echo
echo "$BRANCHES" | tr ':' '\n' | sed 's/=.*//' | while IFS= read -r b; do
    [ -d "$b" ] && df -P "$b" 2>/dev/null | awk 'NR==2{print $5}'
done | tr -d '%' | awk '
    { n++; if($1>mx)mx=$1; if(mn==""||$1<mn)mn=$1 }
    END {
        if (n>1) {
            printf "fullness spread: %d%% (fullest) - %d%% (emptiest) = %d points\n", mx, mn, mx-mn
            if (mx-mn>=15) print "-> noticeably unbalanced; \"mergerfs-tool.sh --quiesce balance\" would help."
            else          print "-> reasonably balanced; balancing not worth the parity re-sync."
        } else if (n==1) {
            print "single branch — nothing to balance."
        } else {
            print "no readable branches found."
        }
    }'
