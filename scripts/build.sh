#!/usr/bin/env bash
# Build the local figma-context-mcp image with corporate CAs baked in.
# CAs are imported in the runtime stage so Node's NODE_EXTRA_CA_CERTS sees
# them when calling api.figma.com.
#
# Works with both podman and docker (BuildKit) — the host CA dir is passed
# as a named build context, not a host bind mount.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_NAME="figma-context-mcp"

# Probe the well-known anchor source dirs across distros, first hit wins.
# Override with HOST_ANCHORS=/path/to/dir.
#
#   /etc/pki/ca-trust/source/anchors/      RHEL / Fedora / CentOS / Rocky
#   /usr/local/share/ca-certificates/      Debian / Ubuntu (.crt only)
#   /etc/ca-certificates/trust-source/anchors/   Arch
HOST_ANCHORS_CANDIDATES=(
    /etc/pki/ca-trust/source/anchors
    /usr/local/share/ca-certificates
    /etc/ca-certificates/trust-source/anchors
)
if [ -z "${HOST_ANCHORS:-}" ]; then
    for d in "${HOST_ANCHORS_CANDIDATES[@]}"; do
        if [ -d "$d" ]; then
            HOST_ANCHORS="$d"
            break
        fi
    done
fi
HOST_ANCHORS="${HOST_ANCHORS:-/etc/pki/ca-trust/source/anchors}"   # last-resort default for the warning path

# Load .env if present (build-time overrides only; never put secrets here).
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

# Pick the container engine. Override with CONTAINER_ENGINE=docker|podman.
ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    else
        echo "ERROR: neither podman nor docker found." >&2
        exit 1
    fi
fi
if ! command -v "$ENGINE" >/dev/null 2>&1; then
    echo "ERROR: requested container engine '$ENGINE' not found." >&2
    exit 1
fi
[ "$ENGINE" = "docker" ] && export DOCKER_BUILDKIT=1

# If the corp anchors dir doesn't exist (typical on a developer laptop without
# the corporate proxy), fall back to an empty dir so the build still succeeds
# and produces an image — it just won't have corp CAs baked in.
CLEANUP=""
if [ ! -d "$HOST_ANCHORS" ]; then
    echo "WARNING: $HOST_ANCHORS not found. Building WITHOUT corporate CAs." >&2
    echo "         For an enterprise build, set HOST_ANCHORS=/path/to/anchors." >&2
    HOST_ANCHORS="$(mktemp -d)"
    CLEANUP="$HOST_ANCHORS"
    trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
fi

VERSION_TAG="${VERSION:-latest}"

# Default to the public npmjs registry; .env (or the caller's env) can
# override with a corp mirror.
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"

BUILD_ARGS=(--build-arg "NPM_REGISTRY=${NPM_REGISTRY}")
[ -n "${VERSION:-}" ] && BUILD_ARGS+=(--build-arg "VERSION=${VERSION}")

echo ">> Building ${IMAGE_NAME} via ${ENGINE} (anchors: ${HOST_ANCHORS}, version: ${VERSION_TAG})"
$ENGINE build \
    --build-context "hostcerts=${HOST_ANCHORS}" \
    ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
    -t "ghcr.io/trick77/${IMAGE_NAME}:latest" \
    -t "localhost/${IMAGE_NAME}:local" \
    -t "localhost/${IMAGE_NAME}:${VERSION_TAG}" \
    -f Containerfile \
    .

echo ">> Done."
$ENGINE images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' | grep "${IMAGE_NAME}" || true
