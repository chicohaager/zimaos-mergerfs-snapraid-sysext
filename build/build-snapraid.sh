#!/bin/sh
# Build a static snapraid binary for one architecture.
# Usage: ./build-snapraid.sh <amd64|arm64>
# Output: ./out/snapraid-<arch>
#
# Cross-arch (building arm64 on an amd64 ZimaCube) needs qemu/binfmt once:
#   docker run --privileged --rm tonistiigi/binfmt --install all
set -eu

ARCH="${1:?usage: build-snapraid.sh <amd64|arm64>}"
SNAPRAID_VERSION="${SNAPRAID_VERSION:-14.5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/out"
mkdir -p "$OUT"

# ZimaOS rule: default docker config is in the read-only area, so point it at
# /DATA/.docker. Use ${VAR-default} (NOT :-): default ONLY when UNSET, so an
# explicit empty value (CI: DOCKER_CONFIG="") is respected and falls back to the
# runner's own ~/.docker instead of the non-existent ZimaOS path.
export DOCKER_CONFIG="${DOCKER_CONFIG-/DATA/.docker}"

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg "SNAPRAID_VERSION=${SNAPRAID_VERSION}" \
    --target export \
    -f "${HERE}/Dockerfile.snapraid" \
    -o "type=local,dest=${OUT}/_${ARCH}" \
    "${HERE}"

mv "${OUT}/_${ARCH}/snapraid" "${OUT}/snapraid-${ARCH}"
rmdir "${OUT}/_${ARCH}" 2>/dev/null || true
chmod +x "${OUT}/snapraid-${ARCH}"
echo "built: ${OUT}/snapraid-${ARCH}"
