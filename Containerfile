FROM node:22-slim

# Install only what's needed at runtime. ca-certificates ships the system
# trust store; the entrypoint script unions our system bundle with any
# corporate CAs mounted at /etc/ssl/ca-anchors via NODE_EXTRA_CA_CERTS.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

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

# Pre-create the image-download dir with node:node. Defensive: the
# compose file bind-mounts $IMAGES_HOST_DIR at the same path inside the
# container and overrides IMAGE_DIR, so this fallback only matters if a
# user runs the image without compose and without an IMAGE_DIR override.
RUN mkdir -p /home/node/images && chown node:node /home/node/images

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER node
WORKDIR /home/node

ENV NODE_ENV=production \
    HOME=/home/node \
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

# Entrypoint script unions any mounted /etc/ssl/ca-anchors/* into a bundle and
# sets NODE_EXTRA_CA_CERTS before exec'ing figma-developer-mcp. Upstream
# speaks HTTP natively (Express) — no mcp-proxy needed. The host publish at
# 127.0.0.1:23149:3333 keeps it loopback-only.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
