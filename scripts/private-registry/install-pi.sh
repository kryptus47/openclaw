#!/usr/bin/env bash
#
# Install openclaw on a Raspberry Pi from your private Verdaccio registry.
# Run this ON the Raspberry Pi.
#
# Usage:
#   curl -sL http://synology:4873/-/web/static/install-pi.sh | bash
#   — or —
#   REGISTRY=http://synology:4873 bash install-pi.sh
#
set -euo pipefail

REGISTRY="${REGISTRY:-}"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  OpenClaw — Raspberry Pi Install"
echo "═══════════════════════════════════════════════════"
echo ""

# ── Ask for registry if not set ──────────────────────────────────────────────
if [ -z "$REGISTRY" ]; then
    read -rp "Verdaccio registry URL (e.g. http://192.168.1.X:4873): " REGISTRY
fi
REGISTRY="${REGISTRY%/}"  # strip trailing slash

# ── Check prerequisites ─────────────────────────────────────────────────────
echo ""
echo "Checking prerequisites..."

if ! command -v node &>/dev/null; then
    echo "Node.js not found. Install Node 22+:"
    echo "  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
    echo "  sudo apt-get install -y nodejs"
    exit 1
fi

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VERSION" -lt 22 ]; then
    echo "Node.js $NODE_VERSION found, but 22+ required."
    echo "  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
    echo "  sudo apt-get install -y nodejs"
    exit 1
fi
echo "  Node.js: $(node -v) ✓"
echo "  Arch:    $(uname -m) ✓"

# ── Check connectivity ──────────────────────────────────────────────────────
echo ""
echo "Checking registry connectivity..."
if ! npm ping --registry "$REGISTRY" 2>/dev/null; then
    echo "Cannot reach $REGISTRY"
    echo "Make sure your Synology is running and Verdaccio is up."
    exit 1
fi
echo "  Registry reachable ✓"

# ── Install ──────────────────────────────────────────────────────────────────
echo ""
echo "Installing openclaw from $REGISTRY ..."

# Check what's available
AVAILABLE=$(npm view openclaw version --registry "$REGISTRY" 2>/dev/null || echo "not found")
echo "  Available version: $AVAILABLE"

if [ "$AVAILABLE" = "not found" ]; then
    echo ""
    echo "openclaw not found on $REGISTRY"
    echo "Publish it first from your dev machine:"
    echo "  REGISTRY=$REGISTRY bash scripts/private-registry/publish.sh"
    exit 1
fi

sudo npm install -g openclaw --registry "$REGISTRY"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Installed openclaw@$(openclaw --version 2>/dev/null || echo "$AVAILABLE")"
echo ""
echo "  To update later:"
echo "    sudo npm install -g openclaw --registry $REGISTRY"
echo ""
echo "  To set registry permanently (no --registry flag needed):"
echo "    npm config set registry $REGISTRY"
echo ""
echo "  Get started:"
echo "    openclaw setup"
echo "════════════════════════════════════════════════════════════"
