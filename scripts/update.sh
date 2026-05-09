#!/usr/bin/env bash
# Update workflow: pin a new upstream npm version in .env, rebuild the image.
# Usage: ./scripts/update.sh <npm-version>
#        ./scripts/update.sh 0.11.0
#
# Versions come from https://www.npmjs.com/package/figma-developer-mcp.
# Use a BARE semver — npm form, no leading 'v'. A leading 'v' is stripped
# automatically so `update.sh v0.11.0` still works.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <npm-version>   (e.g. 0.11.0)" >&2
    exit 2
fi

NEW_VERSION="${1#v}"   # tolerate a leading 'v' from muscle memory

if [ ! -f .env ]; then
    echo "VERSION=${NEW_VERSION}" > .env
    echo ">> Created .env with VERSION=${NEW_VERSION}"
elif grep -qE '^VERSION=' .env; then
    sed -i.bak -E "s|^VERSION=.*|VERSION=${NEW_VERSION}|" .env
    rm -f .env.bak
    echo ">> Updated VERSION in .env to ${NEW_VERSION}"
else
    printf '\nVERSION=%s\n' "${NEW_VERSION}" >> .env
    echo ">> Appended VERSION=${NEW_VERSION} to .env"
fi

echo ">> Rebuilding"
./scripts/build.sh

echo ">> Pruning dangling images"
podman image prune -f

echo ">> Update complete. Pinned version: ${NEW_VERSION}"
echo ">> Restart your MCP client (e.g. OpenCode) to pick up the new image."
