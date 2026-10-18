#!/bin/sh
# Everything to run by hand before `gh release create`, in one place. Each step prints
# its own verdict; the exit code is the number of failed steps.
#
# Usage: sh tests/pre-release-check.sh
#
# Steps that need a tool or script outside the repo (shellcheck, the maintainer's
# base-image and public-data checks) are reported as SKIP when it is missing, never as ok.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
FAILS=0

ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP - $1"; }

step() {
    name="$1"; shift
    if out="$("$@" 2>&1)"; then ok "$name"; else fail "$name"; echo "$out" | sed 's/^/       /'; fi
}

# Release goes out from main, in sync with the remote, with nothing uncommitted.
branch="$(git branch --show-current)"
if [ "$branch" = main ]; then ok "on main"; else fail "on '$branch', not main"; fi
if [ -z "$(git status --porcelain)" ]; then ok "work tree clean"; else fail "uncommitted changes"; fi
git fetch --quiet --tags origin main
if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then
    ok "HEAD == origin/main ($(git rev-parse --short HEAD))"
else
    fail "HEAD differs from origin/main"
fi

step "tests/check-versions.sh" sh tests/check-versions.sh
step "tests/run.sh" sh tests/run.sh

if command -v shellcheck >/dev/null 2>&1; then
    step "shellcheck" sh -c 'shellcheck -s sh -S warning install.sh uninstall.sh scripts/*.sh build/*.sh tests/*.sh'
else
    skip "shellcheck not installed"
fi

for tool in check-base-images.py check-public-data.py; do
    p="$HOME/.claude/bin/$tool"
    if [ -f "$p" ]; then
        step "$tool" python3 "$p" "$REPO"
    else
        skip "$tool not found at $p"
    fi
done

# What the release notes have to cover: commits and files since the last tag.
last="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$last" ]; then
    echo "--- since $last: $(git rev-list --count "$last"..HEAD) commits"
    git diff --stat "$last"..HEAD | tail -n 20
else
    skip "no tag yet"
fi

echo "--- $FAILS failed step(s)"
exit "$FAILS"
