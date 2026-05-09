FROM node:22-slim

# Bake corporate CAs into the image so npm at build time and api.figma.com
# at runtime work behind a TLS-intercepting proxy. Mount provided by
# scripts/build.sh via a named build context — works with both podman and
# docker BuildKit:
#   podman/docker build --build-context hostcerts=/etc/pki/ca-trust/source/anchors ...
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=hostcerts,target=/host-anchors,ro \
    for f in /host-anchors/*; do \
        [ -f "$f" ] || continue; \
        base=$(basename "$f"); \
        cp "$f" "/usr/local/share/ca-certificates/${base%.*}.crt"; \
    done && \
    update-ca-certificates

# NPM_REGISTRY must be passed in by the caller (scripts/build.sh, the CI
# workflow, or `.env`). No default here on purpose — having a "fallback"
# meant two places knew the default and the .env override felt cosmetic.
ARG NPM_REGISTRY
RUN test -n "$NPM_REGISTRY" || { echo "Error: NPM_REGISTRY build-arg is required" >&2; exit 1; } && \
    npm config set registry "$NPM_REGISTRY" && \
    npm ping || { echo "Error: Cannot reach npm registry at ${NPM_REGISTRY}" >&2; exit 1; }

# Pin upstream version. `latest` resolves to the npm dist-tag at build time.
# Use a bare semver here (no leading 'v') — npm tag form, not git tag form.
ARG VERSION=latest

# OCI image metadata. GIT_SHA / IMAGE_SOURCE come from CI and default to
# placeholders for local builds — `unknown` is fine for dev images and
# clearly signals "not from CI".
ARG GIT_SHA=unknown
ARG IMAGE_SOURCE=https://github.com/trick77/mcp-figma-context-podman

LABEL org.opencontainers.image.title="figma-context-mcp" \
      org.opencontainers.image.description="Hardened podman wrapper around GLips/Figma-Context-MCP (Framelink MCP for Figma over native streamable-http)" \
      org.opencontainers.image.source="$IMAGE_SOURCE" \
      org.opencontainers.image.revision="$GIT_SHA" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.licenses="MIT"

# Install the published npm package globally. No git clone, no build step —
# upstream publishes a prebuilt `dist/` to npm and exposes the
# `figma-developer-mcp` bin.
RUN --mount=type=cache,target=/root/.npm,sharing=locked,id=npm-cache \
    npm install -g --omit=dev --prefer-offline "figma-developer-mcp@${VERSION}"

USER node
WORKDIR /home/node

ENV NODE_ENV=production \
    HOME=/home/node \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    FRAMELINK_TELEMETRY=false \
    DO_NOT_TRACK=1 \
    IMAGE_DIR=/home/node/images

EXPOSE 3333

# TCP-only readiness probe: confirms the Express server is listening on :3333.
# Deliberately NOT a JSON-RPC `initialize` — that would create a session per
# probe and pollute logs. A wedged server that has stopped accepting TCP
# connections is the failure mode worth catching here.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD node -e "require('net').createConnection(3333,'127.0.0.1').on('connect',function(){this.end();process.exit(0)}).on('error',()=>process.exit(1))" || exit 1

# Upstream speaks HTTP natively (Express). No mcp-proxy needed — entrypoint
# runs `figma-developer-mcp` directly, bound to 0.0.0.0:3333 inside the
# container netns. The host publish at 127.0.0.1:23149:3333 keeps it
# loopback-only.
ENTRYPOINT ["figma-developer-mcp", "--host", "0.0.0.0", "--port", "3333"]
