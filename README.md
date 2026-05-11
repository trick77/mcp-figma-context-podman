# mcp-figma-context-podman

Hardened podman wrapper around [`GLips/Figma-Context-MCP`](https://github.com/GLips/Figma-Context-MCP) (npm: [`figma-developer-mcp`](https://www.npmjs.com/package/figma-developer-mcp), "Framelink MCP for Figma"). Built for enterprise workstations: a single published image works on default-trust hosts and behind TLS-intercepting corporate proxies (CAs are mounted at runtime, not baked in). Container is `--read-only` with a single project-local bind mount for image downloads, PAT lives in `.env` (chmod 600), exposed only on `127.0.0.1:23149`.

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

# Set FIGMA_API_KEY and IMAGES_HOST_DIR. The one-liner below sets a
# sane default for IMAGES_HOST_DIR (shell expands $HOME so compose
# sees a literal absolute path).
sed -i "s|^IMAGES_HOST_DIR=.*|IMAGES_HOST_DIR=$HOME/.cache/figma-context-mcp|" .env
$EDITOR .env                       # set FIGMA_API_KEY

podman-compose up -d               # pulls + starts
```

**Behind a TLS-intercepting corporate proxy?** Drop your corp root CA(s) (`.crt` / `.pem`) into the `./certs/` directory next to `compose.yaml`, then `podman-compose restart`. The entrypoint unions everything in `./certs/` into a Node-readable bundle, sets `NODE_EXTRA_CA_CERTS`, and logs `entrypoint: loaded N CA anchor file(s)` on startup. Files in `./certs/` are gitignored. Empty dir is a no-op (the default for non-corp users).

> Operators using `compose.yaml` outside a clone need to create a `./certs/` dir next to it (with whatever cert files you want loaded, or empty).

The container is **standalone — start and stop it manually**. There's no auto-start; if you want it on after a reboot, run `podman-compose up -d` again.

Day-to-day:

```sh
podman-compose ps
podman-compose logs -f
podman-compose restart
podman-compose down
```

## Wiring it into OpenCode

Use the `mcp-http-noauth` preset from [`trick77/opencode-presets`](https://github.com/trick77/opencode-presets):

```sh
npm install -g opencode-presets && opencode-presets install mcp-http-noauth
# When prompted:
#   id  -> figma-context-mcp
#   URL -> http://127.0.0.1:23149/mcp
```

The preset patches `~/.config/opencode/opencode.json` with a `type: "remote"` entry. Restart OpenCode; the server appears as `figma-context-mcp`.

Removing the entry later:

```sh
opencode-presets reset mcp.figma-context-mcp
```

## How it works

1. `podman-compose up -d` boots `ghcr.io/trick77/figma-context-mcp:latest` and publishes `127.0.0.1:23149:3333`.
2. Entrypoint reads `/etc/ssl/ca-anchors/*` (read-only mount of `./certs/`), concatenates them to `/tmp/ca-anchors.bundle`, sets `NODE_EXTRA_CA_CERTS`, and exec's the Express server on `:3333`.
3. The MCP client opens a streamable-http connection to `http://127.0.0.1:23149/mcp` and sends `initialize` → `tools/list`.
4. Tool calls hit `api.figma.com` with `FIGMA_API_KEY` from `.env`. `download_figma_images` writes files to `$IMAGES_HOST_DIR` — the same absolute path on host and inside the container, so the path returned by the tool is directly openable on the host.

`pids_limit=64` caps total processes inside the container.

## Image downloads

`download_figma_images` lands files at `$IMAGES_HOST_DIR` on the host. The same path is bind-mounted at the same location inside the container and set as upstream's `IMAGE_DIR` — so the path the tool returns is the *host* path, openable directly by any consuming agent with no translation, no per-project instructions, no `podman cp`.

The First-time setup snippet defaults `IMAGES_HOST_DIR` to `$HOME/.cache/figma-context-mcp`. Override it in `.env` to land files inside a specific project's tree instead, then `podman-compose up -d --force-recreate`.

```sh
# List what's been downloaded
ls -la "$IMAGES_HOST_DIR"

# Wipe between sessions
rm -rf "$IMAGES_HOST_DIR"/*
```

Caveats:
- `IMAGES_HOST_DIR` must be a literal absolute path. `podman-compose` does not expand `$HOME` inside compose defaults, which is why the setup snippet pre-expands it via shell.
- The bind mount uses `:U`, which chowns the host source recursively to the mapped container UID on each `up`. Use an empty/dedicated dir — never a shared dir with files whose ownership you rely on.
- On macOS podman, the path must live under a location the podman machine sees (typically anywhere under `$HOME`).

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

```sh
podman pull ghcr.io/trick77/figma-context-mcp:latest
podman-compose up -d --force-recreate
```

To pin a specific upstream version, change the tag in `compose.yaml` (e.g. `:0.11.0`) and pull. Each CI release is published as `:<upstream-version>-<utc-timestamp>` (immutable), `:<upstream-version>` (moves), and `:latest`.

`podman auto-update` is **intentionally not used** — pulls are explicit and operator-controlled.

## Telemetry

Upstream ships PostHog telemetry on by default. The image disables it via `FRAMELINK_TELEMETRY=false` and `DO_NOT_TRACK=1` baked into the Containerfile's `ENV` — operators don't need to set anything. Runtime egress should be `api.figma.com` only.

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
# 1. Container is up.
podman-compose ps

# 2. Tool list comes back over HTTP.
curl -sN -X POST http://127.0.0.1:23149/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | head

# 3. api.figma.com TLS validates with the mounted bundle.
podman exec figma-context-mcp node -e \
  "require('https').get('https://api.figma.com/v1/me', { headers: { 'X-Figma-Token': process.env.FIGMA_API_KEY }}, r => console.log('HTTP', r.statusCode)).on('error', e => { console.error(e.message); process.exit(1); })"
# expect: HTTP 200 (auth succeeded). 401/403 means PAT is bad. cert error = drop your corp CA into ./certs/ and restart.

# 4. Confirm the CA anchor bundle was loaded (look for the entrypoint message in logs).
podman logs figma-context-mcp 2>&1 | grep -i 'CA anchor'
```

## Hardening

- `read_only` rootfs; tmpfs mount at `/tmp` discarded on exit.
- One writable mount: bind mount of `$IMAGES_HOST_DIR` (absolute host path) at the same path inside the container, for the `download_figma_images` tool.
- One read-only host bind mount: `./certs/` → `/etc/ssl/ca-anchors` (project-local, not a system dir).
- `cap_drop: ALL`, `no-new-privileges`, runs as non-root `node`.
- `pids_limit=64`.
- Loopback-only port publish.

## .env

Holds the PAT. Set `chmod 600 .env` after editing — it's gitignored but still readable to other local users by default.

## Layout

```
.
├── Containerfile                 # single-stage Node 22 + npm install + entrypoint
├── compose.yaml                  # podman-compose service, bind mount for images + CA
├── .env.example                  # runtime config template (.env is gitignored)
├── .upstream-version             # CI-only: pinned figma-developer-mcp npm version
├── certs/                        # operator-supplied corp root CAs (.crt/.pem); gitignored
├── scripts/
│   └── entrypoint.sh             # runtime CA union + exec figma-developer-mcp
├── README.md
└── AGENTS.md                     # rules for coding agents working on this repo
```

## Uninstall

```sh
podman-compose down
rm -rf "$IMAGES_HOST_DIR"/*
podman rmi ghcr.io/trick77/figma-context-mcp:latest
opencode-presets reset mcp.figma-context-mcp     # if you ran the preset
```
