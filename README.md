# mcp-figma-context-podman

Hardened podman wrapper around [`GLips/Figma-Context-MCP`](https://github.com/GLips/Figma-Context-MCP) (npm: [`figma-developer-mcp`](https://www.npmjs.com/package/figma-developer-mcp), "Framelink MCP for Figma"). Built for enterprise workstations: corporate CAs baked in at build time, container is `--read-only` with a single named volume for image downloads, PAT lives in `.env` (chmod 600), exposed only on `127.0.0.1:23149`.

Upstream speaks **streamable-http natively** (Express). No stdio bridge, no `mcp-proxy` — the container runs the published npm bin directly.

## Using it

Paste a Figma file URL (`https://www.figma.com/file/<KEY>/...` or `.../design/<KEY>/...`) into your inference client and tell it what you want. The agent calls `get_figma_data` (and optionally `download_figma_images`) over MCP and uses the simplified design context to write code.

Tool reference: [framelink.ai/docs](https://www.framelink.ai/docs/quickstart) and the [upstream README](https://github.com/GLips/Figma-Context-MCP).

## Prerequisites

- `podman` ≥ 4.4
- `podman-compose` ≥ 1.0.6
- Figma PAT with read-only scopes: File content, Variables (optionally Dev resources, Library content). No write scopes.

## First-time setup

`compose.yaml` references the prebuilt amd64 image at `ghcr.io/trick77/figma-context-mcp:latest`. Podman pulls it on first start.

```sh
cp .env.example .env
chmod 600 .env
$EDITOR .env                       # set FIGMA_API_KEY
podman-compose up -d               # pulls + starts
./scripts/install-opencode.sh      # writes the OpenCode MCP entry
```

> **Behind a TLS-intercepting corporate proxy?** The published image has no corporate CAs baked in, so api.figma.com calls will fail with cert errors. Build locally instead — see [Building from source](#building-from-source).

Then restart OpenCode. The MCP server appears as `figma-context-mcp` and points at `http://127.0.0.1:23149/mcp`.

The container is **standalone — start and stop it manually**. There's no auto-start; if you want it on after a reboot, run `podman-compose up -d` again.

Day-to-day:

```sh
podman-compose ps
podman-compose logs -f
podman-compose restart
podman-compose down
```

## How it works

1. `podman-compose up -d` boots `ghcr.io/trick77/figma-context-mcp:latest` and publishes `127.0.0.1:23149:3333`.
2. Inside the container, the upstream Express server listens on `:3333`.
3. The MCP client opens a streamable-http connection to `http://127.0.0.1:23149/mcp` and sends `initialize` → `tools/list`.
4. Tool calls hit `api.figma.com` with `FIGMA_API_KEY` from `.env`. `download_figma_images` writes files into the named volume `figma-images` mounted at `/home/node/images`.

`pids_limit=64` caps total processes inside the container.

## Image downloads

The `download_figma_images` tool writes PNG/JPG/SVG files to `/home/node/images` inside the container. That path is backed by the named podman volume `figma-images` — it's the only writable surface (the rootfs is `read_only`).

```sh
# Where the volume lives on the host
podman volume inspect figma-images

# List downloaded files
podman exec figma-context-mcp ls -la /home/node/images

# Wipe (e.g. after the agent grabbed a lot during a session)
podman-compose down
podman volume rm figma-images
podman-compose up -d
```

## Rotating the PAT

Figma personal access tokens expire after 90 days max — rotation is routine, not exceptional. Mint a new read-only token at https://www.figma.com/developers/api#access-tokens, then:

```sh
$EDITOR .env                                  # update FIGMA_API_KEY
podman-compose restart
```

Verify the new token works:

```sh
podman exec figma-context-mcp node -e \
  "require('https').get('https://api.figma.com/v1/me', { headers: { 'X-Figma-Token': process.env.FIGMA_API_KEY }}, r => console.log('HTTP', r.statusCode))"
# expect: HTTP 200
```

## Updates

Prebuilt image:

```sh
podman pull ghcr.io/trick77/figma-context-mcp:latest
podman-compose up -d --force-recreate
```

Local build:

```sh
./scripts/update.sh 0.11.0                  # any version from npm (bare semver, no leading 'v')
podman-compose up -d --force-recreate
```

`update.sh` writes `VERSION=0.11.0` into `.env`, rebuilds the image with fresh corporate CAs, and prunes dangling layers. `podman auto-update` is **intentionally not used** — the image is built/pulled on a controlled host, never refreshed at runtime.

## Telemetry

Upstream ships PostHog telemetry on by default. The image disables it via `FRAMELINK_TELEMETRY=false` and `DO_NOT_TRACK=1` (also repeated in `.env.example`). Runtime egress should be `api.figma.com` only.

## Network posture

Port published as `127.0.0.1:23149:3333` in `compose.yaml`. The container's internal `0.0.0.0:3333` is in the container netns and is not the host interface.

```sh
ss -ltn 'sport = :23149'                          # only 127.0.0.1:23149 (and/or [::1]:23149)
curl -i http://127.0.0.1:23149/mcp                # 406 = reachable (no Accept header)
curl -i http://<host-external-ip>:23149/mcp       # connection refused
```

For cross-host access, front it with an authenticated reverse proxy on the host. Do not change the bind to `0.0.0.0`.

## Verification

```sh
# 1. Image built with corp CAs (count certs in the runtime bundle).
podman run --rm --entrypoint sh ghcr.io/trick77/figma-context-mcp:latest -c \
  'awk "/-----BEGIN CERTIFICATE-----/{c++} END{print c\" certs in bundle\"}" /etc/ssl/certs/ca-certificates.crt'

# 2. Container is up.
podman-compose ps

# 3. Tool list comes back over HTTP.
curl -sN -X POST http://127.0.0.1:23149/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | head

# 4. api.figma.com TLS validates with the baked-in bundle.
podman exec figma-context-mcp node -e \
  "require('https').get('https://api.figma.com/v1/me', { headers: { 'X-Figma-Token': process.env.FIGMA_API_KEY }}, r => console.log('HTTP', r.statusCode)).on('error', e => { console.error(e.message); process.exit(1); })"
# expect: HTTP 200 (auth succeeded). 401/403 means PAT is bad. cert error = CA chain not validated.
```

## Hardening

- `read_only` rootfs; tmpfs mount at `/tmp` discarded on exit.
- Single writable mount: named volume `figma-images` at `/home/node/images` for the `download_figma_images` tool.
- `cap_drop: ALL`, `no-new-privileges`, runs as non-root `node`.
- No host bind mounts.
- `pids_limit=64`.
- Loopback-only port publish.

## .env

Holds the PAT. Set `chmod 600 .env` after editing — it's gitignored but still readable to other local users by default.

## Layout

```
.
├── Containerfile                 # single-stage Node 22 + npm install
├── compose.yaml                  # podman-compose service definition + named volume
├── .env.example                  # config template (.env is gitignored)
├── scripts/
│   ├── build.sh                  # podman build with --build-context for host anchors
│   ├── update.sh                 # pin a new upstream npm version, rebuild
│   └── install-opencode.sh       # write the OpenCode MCP "remote" entry
├── README.md
└── AGENTS.md                     # rules for coding agents working on this repo
```

## Building from source

Required for TLS-intercepting corporate proxies (prebuilt CI image has no corp CAs), pinning a different upstream version, or building on a controlled host.

Build host needs corporate root CA(s) in `/etc/pki/ca-trust/source/anchors/` (RHEL/Fedora). Debian/Ubuntu and Arch paths are auto-detected; override with `HOST_ANCHORS=/path/to/anchors`. Empty dir produces an image without corp CAs (warns).

```sh
cp .env.example .env
$EDITOR .env                       # FIGMA_API_KEY, optionally VERSION
./scripts/build.sh
podman-compose up -d
./scripts/install-opencode.sh
```

`build.sh` supports docker via `CONTAINER_ENGINE=docker`. It tags the build as `ghcr.io/trick77/figma-context-mcp:latest`, shadowing the registry image without further config changes.

## Uninstall

```sh
podman-compose down
podman volume rm figma-images
podman rmi ghcr.io/trick77/figma-context-mcp:latest
# Remove "figma-context-mcp" from .mcp in ~/.config/opencode/opencode.json
```
