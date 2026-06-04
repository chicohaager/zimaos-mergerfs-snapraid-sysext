#!/bin/sh
# Build the mergerfs-tools maintenance image (used by scripts/mergerfs-tool.sh).
# No local build context is sent — the Dockerfile fetches the pinned scripts via ADD.
# The wrapper auto-builds on first use too; this script is for pre-building / CI / a
# deliberate version bump (edit MFT_SHA in Dockerfile.mergerfs-tools).
set -eu
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${MFT_IMAGE:-mergerfs-tools:local}"
DOCKERFILE="${SELF_DIR}/Dockerfile.mergerfs-tools"
# ':-'-trap (KB §2.3): default only when UNSET (ZimaOS host); respect explicit empty.
export DOCKER_CONFIG="${DOCKER_CONFIG-/DATA/.docker}"

[ -f "$DOCKERFILE" ] || { echo "missing $DOCKERFILE"; exit 1; }
echo "building $IMAGE from $(basename "$DOCKERFILE") (no local context)"
docker build -t "$IMAGE" - < "$DOCKERFILE"
echo "built $IMAGE"
