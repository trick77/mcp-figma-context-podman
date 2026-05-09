#!/bin/sh
# Container entrypoint. Builds an extra-CA bundle from any PEM/CRT files
# mounted at /etc/ssl/extra-ca and points Node at it via NODE_EXTRA_CA_CERTS,
# then exec's figma-developer-mcp.
#
# Why: lets a single published image work both on default-trust hosts AND
# behind TLS-intercepting corporate proxies. Drop the corp anchor dir at
# /etc/ssl/extra-ca:ro in the container (see compose.yaml) and Node will
# trust the mounted certs without a rebuild.
#
# Node's NODE_EXTRA_CA_CERTS takes a single PEM file (one or many concatenated
# certs), not a directory. /tmp is a tmpfs (see compose.yaml), so the
# concatenated bundle write succeeds with a read-only rootfs.
set -eu

CERT_DIR=/etc/ssl/extra-ca
BUNDLE=/tmp/extra-ca.bundle

if [ -d "$CERT_DIR" ]; then
    # Match common anchor file extensions; ignore other content. RHEL ships
    # .crt; Debian/Ubuntu use .crt; some sites stage .pem. Subshell + `find`
    # avoids glob no-match errors under `set -u`/`set -e`.
    files=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.pem' \) 2>/dev/null | sort)
    if [ -n "$files" ]; then
        # shellcheck disable=SC2086
        cat $files > "$BUNDLE"
        export NODE_EXTRA_CA_CERTS="$BUNDLE"
        echo "entrypoint: loaded $(echo "$files" | wc -l | tr -d ' ') extra CA file(s) into $BUNDLE" >&2
    fi
fi

exec figma-developer-mcp --host 0.0.0.0 --port 3333 "$@"
