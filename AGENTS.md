# AGENTS.md

This file provides guidance to coding agents working in this repository.

This repo is a thin podman wrapper around upstream `GLips/Figma-Context-MCP` (npm: `figma-developer-mcp`, "Framelink MCP for Figma"). It contains no application code — only a `Containerfile`, a `compose.yaml`, an `.env.example`, a small entrypoint shell script, and CI workflows. The container is **standalone, started manually** (typically via `podman-compose up -d`) — no Quadlet, no systemd auto-start. Read `README.md` for the user-facing setup flow; this file captures rules that aren't obvious from the code.

## Architecture in one paragraph

Upstream `figma-developer-mcp` speaks **HTTP natively** (Express, default mode). Stdio is opt-in (`--stdio`). The container therefore runs the published npm bin directly — there is **no** stdio-to-HTTP proxy. The server listens on `0.0.0.0:3333` inside the container netns; the host publishes `127.0.0.1:23149:3333`, so the endpoint is loopback-only. Clients connect to `http://127.0.0.1:23149/mcp` as a `type: "remote"` server (in OpenCode, wired up via the `mcp-remote-add-noauth` preset from `trick77/opencode-presets`). The upstream `download_figma_images` tool writes files to `/home/node/images`, backed by a named podman volume `figma-images`.

## Hard constraints

- **No mcp-proxy.** Upstream HTTP is native. Don't introduce a stdio bridge "for symmetry" with the sibling `mcp-figma-podman` repo. The entrypoint runs `figma-developer-mcp` directly.
- **Loopback-only network exposure.** `compose.yaml` publishes the port as `127.0.0.1:23149:3333`. The `127.0.0.1` prefix is **load-bearing** — it makes the endpoint host-only. Never drop it or change to `0.0.0.0`. Container-internal bind stays `0.0.0.0:3333` (private network namespace).
- **Read-only by design.** PAT is a least-privilege read-only token (see `.env.example`). Container also runs `read_only: true`, `cap_drop: ALL`, `no-new-privileges`, non-root `node` user. Do not relax these.
- **Writable surfaces are limited and explicit.** Only two: tmpfs `/tmp` (for `/tmp/extra-ca.bundle` produced by the entrypoint), and the named volume `figma-images` mounted at `/home/node/images` (for the `download_figma_images` tool). Do not add other writable mounts.
- **One read-only host bind mount is allowed**, and only one: `/etc/pki/ca-trust/source/anchors:/etc/ssl/extra-ca:ro,Z`. The entrypoint reads it to build the extra-CA bundle. Without this exception, every corporate user would need a rebuilt image. Do not add other host bind mounts.
- **CAs are mounted at runtime, not baked at build time.** The Containerfile must NOT import host anchors via `--mount=type=bind,from=hostcerts,...` etc. The published GHCR image is universal — it works on default-trust hosts (mount commented out) AND behind TLS-intercepting proxies (mount enabled).
- **No memory or cpu caps.** Rootless cgroup v2 hosts often lack `cpu`/`memory` controller delegation, so `mem_limit`/`cpus` makes the container fail to start. Only `pids_limit` is set.
- **Telemetry off.** `FRAMELINK_TELEMETRY=false` and `DO_NOT_TRACK=1` are baked into the image and repeated in `.env.example`. Upstream PostHog telemetry is on by default — do not remove these env vars. Runtime egress should be `api.figma.com` only.
- **The PAT is a runtime secret.** It lives in `.env` (chmod 600 manually), read by compose's `env_file=`. Never bake it into the image, never put it in the OpenCode config.

## Naming / tooling conventions

- Use `Containerfile`, never `Dockerfile`.
- Use `compose.yaml`, never `docker-compose.yml`. All YAML files use `.yaml`.
- Invoke `podman` and `podman-compose`. Don't introduce `docker` commands.
- `compose.yaml` references `ghcr.io/trick77/figma-context-mcp:latest`. CI publishes that tag plus `:<UPSTREAM_VERSION>` and `:<UPSTREAM_VERSION>-<UTC-timestamp>` on every push to `master`.
- Default branch is `master`. Never `main`.

## Editing the Containerfile

- Single-stage. Source is the published npm package `figma-developer-mcp@${VERSION}` — not a git clone, not a build step. Don't switch to a multi-stage builder unless upstream stops publishing prebuilt `dist/`.
- Version pinning uses **bare semver** (no leading `v`) — npm version, not git tag.
- Runtime user is `node` (uid 1000). Don't switch back to root.
- ENTRYPOINT is `/usr/local/bin/entrypoint.sh`. The script unions any `/etc/ssl/extra-ca/*.crt|.pem` into `/tmp/extra-ca.bundle` and exports `NODE_EXTRA_CA_CERTS` before `exec figma-developer-mcp --host 0.0.0.0 --port 3333`. Don't bypass it.
- Don't add `--stdio` (would disable HTTP). Don't add `--skip-image-downloads` (the volume exists for that tool to use).
- HEALTHCHECK is a **TCP-only** probe of `127.0.0.1:3333`. Don't promote it to a JSON-RPC `initialize` call.

## CI build workflow

- `.github/workflows/build.yaml` triggers on push to `master`, PR to `master`, and manual dispatch. PRs run the smoke test only; `master` push runs smoke test then publishes to GHCR.
- Single source of truth for `UPSTREAM_VERSION` is `.env.example` (`VERSION=`). The workflow `awk`s it out — no second pin to keep in sync.
- amd64-only by design. arm64 under qemu is too slow for the audience.
- `.github/workflows/upstream-watch.yaml` polls the npm registry daily and opens a PR bumping `.env.example` `VERSION=` when a newer version lands. The PR's `Build` check smoke-tests the new upstream before merge.

## Updates

- Operators: `podman pull && podman-compose up -d --force-recreate`. To pin a specific upstream version, change the tag in `compose.yaml` (e.g. `:0.11.0`).
- No `podman auto-update` — pulls are explicit and operator-controlled.

## What not to add

- No `Dockerfile`, no `docker-compose.yml`.
- No mcp-proxy / sparfenyuk-style stdio bridge — upstream is HTTP-native.
- No `0.0.0.0` host publish.
- No host bind mounts other than the read-only CA anchor mount.
- No build-time CA bake-in. (We deleted `scripts/build.sh`/`scripts/update.sh` for this reason.)
- No CA files, no PAT, no `.env` checked in.
- No package.json or Node code in this repo — server code comes from the npm package.
- No `podman auto-update` labels.
