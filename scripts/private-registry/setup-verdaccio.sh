#!/usr/bin/env bash
#
# Run this ON your Synology via SSH, or paste into Container Manager.
# Sets up Verdaccio (private npm registry) as a Docker container.
#
# Usage:
#   ssh your-synology
#   bash setup-verdaccio.sh
#
set -euo pipefail

VERDACCIO_PORT="${VERDACCIO_PORT:-4873}"
VERDACCIO_DIR="${VERDACCIO_DIR:-/volume1/docker/verdaccio}"

echo "═══════════════════════════════════════════════════"
echo "  Verdaccio Private NPM Registry — Synology Setup"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Port:      $VERDACCIO_PORT"
echo "  Data dir:  $VERDACCIO_DIR"
echo ""

# ── Create directory structure ───────────────────────────────────────────────
mkdir -p "$VERDACCIO_DIR/storage"
mkdir -p "$VERDACCIO_DIR/plugins"
mkdir -p "$VERDACCIO_DIR/conf"

# ── Write config ─────────────────────────────────────────────────────────────
cat > "$VERDACCIO_DIR/conf/config.yaml" << 'YAML'
# Verdaccio config — private npm registry
storage: /verdaccio/storage
auth:
  htpasswd:
    file: /verdaccio/storage/htpasswd
    # Allow self-registration (first publish creates the user).
    # Set to -1 after creating your user to lock registration.
    max_users: 10

# Upstream: anything not published locally is fetched from npmjs.
uplinks:
  npmjs:
    url: https://registry.npmjs.org/

packages:
  # Your private openclaw package — never proxy to npmjs
  'openclaw':
    access: $all
    publish: $authenticated
    unpublish: $authenticated

  # Everything else — proxy to npmjs (acts as a cache)
  '**':
    access: $all
    publish: $authenticated
    proxy: npmjs

# Listen on all interfaces so LAN devices (Pi, dev machine) can reach it
listen:
  - 0.0.0.0:4873

# Log
log: { type: stdout, format: pretty, level: info }

# Max body size for large tarballs
max_body_size: 200mb
YAML

# ── Fix permissions (Verdaccio runs as uid 10001 in the container) ───────────
chown -R 10001:10001 "$VERDACCIO_DIR"

echo "Config written to $VERDACCIO_DIR/conf/config.yaml"
echo ""

# ── Start container ──────────────────────────────────────────────────────────
echo "Starting Verdaccio container..."

docker run -d \
  --name verdaccio \
  --restart unless-stopped \
  -p "${VERDACCIO_PORT}:4873" \
  -v "${VERDACCIO_DIR}/conf:/verdaccio/conf" \
  -v "${VERDACCIO_DIR}/storage:/verdaccio/storage" \
  -v "${VERDACCIO_DIR}/plugins:/verdaccio/plugins" \
  verdaccio/verdaccio:latest

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Verdaccio is running!"
echo ""
echo "  Web UI:    http://$(hostname -I | awk '{print $1}'):${VERDACCIO_PORT}"
echo "  Registry:  http://$(hostname -I | awk '{print $1}'):${VERDACCIO_PORT}/"
echo ""
echo "  Next steps:"
echo "    1. Create a user (run on any machine):"
echo "       npm adduser --registry http://SYNOLOGY_IP:${VERDACCIO_PORT}"
echo ""
echo "    2. Then publish from your dev machine:"
echo "       npm publish --registry http://SYNOLOGY_IP:${VERDACCIO_PORT}"
echo ""
echo "    3. Install on Raspberry Pi:"
echo "       npm install -g openclaw --registry http://SYNOLOGY_IP:${VERDACCIO_PORT}"
echo "════════════════════════════════════════════════════════════"
