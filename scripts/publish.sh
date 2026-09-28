#!/usr/bin/env bash
# Builds the probe agent for linux/amd64 + linux/arm64 and pushes it.
#
#   docker login ghcr.io -u <user>     # once, token with write:packages
#   IMAGE=ghcr.io/<user>/privan-probe-agent scripts/publish.sh
#
# TAG (default latest) picks the tag; a non-latest TAG also moves latest.
set -euo pipefail

: "${IMAGE:?set IMAGE, e.g. IMAGE=ghcr.io/<user>/privan-probe-agent}"
TAG="${TAG:-latest}"
BUILDER=privan-probe-agent

cd "$(dirname "$0")/.."

# The default docker driver can't push multi-platform images.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
fi

tags=(-t "$IMAGE:$TAG")
[[ "$TAG" != latest ]] && tags+=(-t "$IMAGE:latest")

docker buildx build \
  --builder "$BUILDER" \
  --platform linux/amd64,linux/arm64 \
  "${tags[@]}" \
  --push \
  .

echo "pushed $IMAGE:$TAG"
