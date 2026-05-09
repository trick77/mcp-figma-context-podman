# mcp-figma-context-podman

Hardened podman wrapper around [`GLips/Figma-Context-MCP`](https://github.com/GLips/Figma-Context-MCP) (npm: [`figma-developer-mcp`](https://www.npmjs.com/package/figma-developer-mcp), "Framelink MCP for Figma"). Built for enterprise workstations: a single published image works on default-trust hosts and behind TLS-intercepting corporate proxies (CAs are mounted at runtime, not baked in). Container is `--read-only` with a single named volume for image downloads, PAT lives in `.env` (chmod 600), exposed only on `127.0.0.1:23149`.

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
```

The default `compose.yaml` mounts `/etc/pki/ca-trust/source/anchors` (the RHEL/Fedora system anchor dir) read-only into the container. The entrypoint unions every `.crt`/`.pem` it finds there into a Node-readable bundle and points `NODE_EXTRA_CA_CERTS` at it. **No rebuild needed** — drop a new corp cert into the host anchor dir and `podman-compose restart`.

If your distro keeps anchors elsewhere (Debian/Ubuntu use `/usr/local/share/ca-certificates/`), edit the `volumes:` line in `compose.yaml`. If you don't have a TLS-intercepting proxy, comment the line out.

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
2. Entrypoint reads `/etc/ssl/ca-anchors/*` (read-only mount of the host anchor dir), concatenates them to `/tmp/ca-anchors.bundle`, sets `NODE_EXTRA_CA_CERTS`, and exec's the Express server on `:3333`.
3. The MCP client opens a streamable-http connection to `http://127.0.0.1:23149/mcp` and sends `initialize` → `tools/list`.
4. Tool calls hit `api.figma.com` with `FIGMA_API_KEY` from `.env`. `download_figma_images` writes files into the named volume `figma-images` mounted at `/home/node/images`.

`pids_limit=64` caps total processes inside the container.

## Image downloads

The `download_figma_images` tool writes PNG/JPG/SVG files to `/home/node/images` inside the container. That path is backed by the named podman volume `figma-images` — it's the only writable surface besides `/tmp`.

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

```sh
podman pull ghcr.io/trick77/figma-context-mcp:latest
podman-compose up -d --force-recreate
```

To pin a specific upstream version, change the tag in `compose.yaml` (e.g. `:0.11.0`) and pull. Each CI release is published as `:<upstream-version>-<utc-timestamp>` (immutable), `:<upstream-version>` (moves), and `:latest`.

`podman auto-update` is **intentionally not used** — pulls are explicit and operator-controlled.

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
# expect: HTTP 200 (auth succeeded). 401/403 means PAT is bad. cert error = corp CA mount missing or wrong path.

# 4. Confirm the CA anchor bundle was loaded (look for the entrypoint message in logs).
podman logs figma-context-mcp 2>&1 | grep -i 'CA anchor'
```

## Hardening

- `read_only` rootfs; tmpfs mount at `/tmp` discarded on exit.
- Two writable mounts: named volume `figma-images` for the `download_figma_images` tool; `/etc/ssl/ca-anchors` mounted **read-only** for corp CAs.
- `cap_drop: ALL`, `no-new-privileges`, runs as non-root `node`.
- No host bind mounts other than the read-only CA anchor mount.
- `pids_limit=64`.
- Loopback-only port publish.

## .env

Holds the PAT. Set `chmod 600 .env` after editing — it's gitignored but still readable to other local users by default.

## Layout

```
.
├── Containerfile                 # single-stage Node 22 + npm install + entrypoint
├── compose.yaml                  # podman-compose service, named volume, CA mount
├── .env.example                  # config template (.env is gitignored)
├── scripts/
│   └── entrypoint.sh             # runtime CA union + exec figma-developer-mcp
├── README.md
└── AGENTS.md                     # rules for coding agents working on this repo
```

## Uninstall

```sh
podman-compose down
podman volume rm figma-images
podman rmi ghcr.io/trick77/figma-context-mcp:latest
opencode-presets reset mcp.figma-context-mcp     # if you ran the preset
```
