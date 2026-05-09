# AGENTS.md

This file provides guidance to coding agents working in this repository.

This repo is a thin podman wrapper around upstream `GLips/Figma-Context-MCP` (npm: `figma-developer-mcp`, "Framelink MCP for Figma"). It contains no application code — only a `Containerfile`, a `compose.yaml`, an `.env.example`, and shell scripts under `scripts/`. The container is **standalone, started manually** (typically via `podman-compose up -d`) — no Quadlet, no systemd auto-start. Read `README.md` for the user-facing build/install/run flow; this file captures rules that aren't obvious from the code.

## Architecture in one paragraph

Upstream `figma-developer-mcp` speaks **HTTP natively** (Express, default mode). Stdio is opt-in (`--stdio`). The container therefore runs the published npm bin directly — there is **no** stdio-to-HTTP proxy. The server listens on `0.0.0.0:3333` inside the container netns; the host publishes `127.0.0.1:23149:3333`, so the endpoint is loopback-only. The MCP client (OpenCode) connects to `http://127.0.0.1:23149/mcp` as a `type: "remote"` server. The upstream `download_figma_images` tool writes files to `/home/node/images`, which is the only writable mount (a named podman volume `figma-images`).

## Hard constraints

- **No mcp-proxy.** Upstream HTTP is native. Don't introduce a stdio bridge "for symmetry" with the sibling `mcp-figma-podman` repo. The entrypoint runs `figma-developer-mcp` directly.
- **Loopback-only network exposure.** `compose.yaml` publishes the port as `127.0.0.1:23149:3333`. The `127.0.0.1` prefix is **load-bearing** — it makes the endpoint host-only. Never drop it or change to `0.0.0.0`. If cross-host access is needed, front it with an authenticated reverse proxy on the host. Container-internal bind stays `0.0.0.0:3333` (private network namespace).
- **Read-only by design.** The Figma PAT must be a least-privilege read-only token (see `.env.example`). Container also runs `read_only: true`, `cap_drop: ALL`, `no-new-privileges`, non-root `node` user. Do not relax these.
- **Single writable surface.** The named volume `figma-images` mounted at `/home/node/images` (matching `IMAGE_DIR` in the Containerfile env) is the **only** writable path. tmpfs `/tmp` is the runtime scratch. Do not add bind mounts to host paths.
- **No memory or cpu caps.** Rootless cgroup v2 hosts often lack `cpu`/`memory` controller delegation, so applying `mem_limit`/`cpus` makes the container fail to start. Only `pids_limit` is set.
- **Telemetry off.** `FRAMELINK_TELEMETRY=false` and `DO_NOT_TRACK=1` are baked into the image and repeated in `.env.example`. Upstream PostHog telemetry is on by default — do not remove these env vars. Runtime egress should be `api.figma.com` only.
- **Corporate CAs come from the build host's anchor dir** via `--build-context hostcerts=/etc/pki/ca-trust/source/anchors`. `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt` makes Node use the system bundle (Node does not read it by default). Do not commit any CA material; do not add a `certs/` directory; do not mount certs at runtime.
- **The PAT is a runtime secret.** It lives in `.env` (chmod 600), read by compose's `env_file=`. Never bake it into the image, never put it in the OpenCode config.

## Naming / tooling conventions

- Use `Containerfile`, never `Dockerfile`.
- Use `compose.yaml`, never `docker-compose.yml`. All YAML files use `.yaml`.
- Invoke `podman` and `podman-compose`. Don't introduce `docker` commands.
- `compose.yaml` references `ghcr.io/trick77/figma-context-mcp:latest`. `build.sh` tags local builds with that name plus `localhost/figma-context-mcp:local` and `localhost/figma-context-mcp:<VERSION>`. Keep all three in sync when changing build logic.
- Shell scripts live under `scripts/` and `cd "$(dirname "$0")/.."` so they work from any CWD.

## Editing the Containerfile

- Single-stage. Source is the published npm package `figma-developer-mcp@${VERSION}` — not a git clone, not a build step. Don't switch to a multi-stage builder unless upstream stops publishing prebuilt `dist/`.
- Version pinning uses **bare semver** (no leading `v`). It's an npm version, not a git tag. `update.sh` strips a leading `v` defensively.
- The CA-import `RUN --mount=type=bind,from=hostcerts,...` block is load-bearing — without it, `NODE_EXTRA_CA_CERTS` points at a bundle missing the corp CAs and `api.figma.com` calls fail behind a TLS-intercepting proxy.
- Runtime user is `node` (uid 1000). Don't switch back to root.
- ENTRYPOINT runs `figma-developer-mcp --host 0.0.0.0 --port 3333`. Don't add `--stdio` (would disable HTTP). Don't add `--skip-image-downloads` (the volume exists for that tool to use).
- HEALTHCHECK is a **TCP-only** probe of `127.0.0.1:3333`. Don't promote it to a JSON-RPC `initialize` call.

## Updates

- Routine update = `./scripts/update.sh X.Y.Z`. The script writes/updates `VERSION=` in `.env` (consumed by `scripts/build.sh`) and rebuilds.
- After rebuild: `podman-compose up -d --force-recreate`.
- No auto-update mechanism by design. Image is rebuilt on the build host, never pulled at runtime.

## What not to add

- No `Dockerfile`, no `docker-compose.yml`.
- No mcp-proxy / sparfenyuk-style stdio bridge — upstream is HTTP-native.
- No `0.0.0.0` host publish, no host bind mounts (`-v` / `Volume=` against host paths). Named volumes only.
- No CA files, no PAT, no `.env` checked in. `.env`/`.env.bak`/`*.local` are gitignored.
- No package.json or Node code in this repo — server code comes from the npm package.
- No `podman auto-update` labels — the wrapper exists so the runtime never has to pull.
