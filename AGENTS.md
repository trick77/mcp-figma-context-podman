# AGENTS.md

Rules for agents working in this repo. Architecture and file layout are visible from the source — only behaviors that aren't obvious are listed here.

## Don't

- **Don't change the host port bind from `127.0.0.1` to `0.0.0.0`.** The loopback prefix is the security boundary. For cross-host access, front it with an authenticated reverse proxy on the host.
- **Don't add `--stdio`** to the entrypoint args. It would "work" but disable the HTTP transport this whole wrapper exists to serve.
- **Don't add `--skip-image-downloads`.** The `$IMAGES_HOST_DIR` bind mount exists for the `download_figma_images` tool — disabling it leaves a dead mount.
- **Don't promote the HEALTHCHECK to a JSON-RPC `initialize` call.** Upstream creates a session per `initialize`; healthchecks would spawn sessions on a 30s interval. Keep it a TCP probe.
- **Don't add `mem_limit`/`cpus` (compose) or `MemoryMax`/`CPUQuota` (Quadlet).** Rootless cgroup v2 hosts often lack `cpu`/`memory` controller delegation; the container fails to start. `pids_limit` is the only ceiling that's safe rootless.
- **Don't remove `FRAMELINK_TELEMETRY=false` or `DO_NOT_TRACK=1` from the Containerfile's `ENV`.** Upstream PostHog telemetry is on by default; both env vars are belt-and-suspenders. They live in the image, not `.env.example`, so operators don't have to know they exist. Runtime egress should be `api.figma.com` only.
- **Don't bake corporate CAs into the image at build time.** CAs are mounted at runtime (`/etc/ssl/ca-anchors`, read by `scripts/entrypoint.sh`). The published GHCR image must stay universal — same image for default-trust and TLS-intercepting hosts.
- **Don't bind-mount system dirs** (e.g. `/etc/pki/...`, `/usr/local/share/ca-certificates/`). That mauls the host's SELinux labels and breaks `update-ca-trust`. Project-local or `$HOME`-scoped bind mounts are fine — current examples: `./certs/` → `/etc/ssl/ca-anchors` (ro) and `$IMAGES_HOST_DIR` (default `$HOME/.cache/figma-mcp-images`) at the same path inside the container (rw, same-path so the tool-returned path is host-valid).
- **Don't put the PAT in the OpenCode config.** It lives in `.env` (chmod 600). One rotation point.
- **Don't add `podman auto-update` labels.** Pulls are operator-controlled by design.
- **Don't add `package.json` or Node source here.** Server code comes from the npm package; this repo is a wrapper only.

## Do

- **Default branch is `master`, never `main`.**
- **`.upstream-version` is the single source of truth for the upstream npm version.** `.github/workflows/build.yaml` reads it; `.github/workflows/upstream-watch.yaml` bumps it. Don't introduce a second pin (the `ARG VERSION=latest` in `Containerfile` is just a fallback for ad-hoc local builds — CI always passes the pin).
- **Use bare semver in `.upstream-version`** (no leading `v`) — it's an npm version, not a git tag.
- **`.env.example` is runtime-only.** The CI build pin does not belong there. Do not put any build-time vars in it.
- **amd64-only.** Don't add `linux/arm64` to `platforms:` without a real arm64 consumer; qemu cross-build is 5–10× slower than native.
- **Use `Containerfile`/`compose.yaml`/`podman`/`podman-compose`.** Not `Dockerfile`, not `docker-compose.yml`, not `docker`.
