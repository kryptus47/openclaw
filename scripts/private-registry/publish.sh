#!/usr/bin/env bash
#
# Build openclaw and publish to your private Verdaccio registry.
# Run this on your dev machine (Linux VM or WSL).
#
# Usage:
#   REGISTRY=http://synology:4873 bash scripts/private-registry/publish.sh
#
set -euo pipefail

REGISTRY="${REGISTRY:-http://synology:4873}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

echo "═══════════════════════════════════════════════════"
echo "  Build & Publish openclaw to private registry"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Registry:  $REGISTRY"
echo "  Project:   $PROJECT_ROOT"
echo ""

# ── 1. Install deps ─────────────────────────────────────────────────────────
echo "[1/4] Installing dependencies..."
pnpm install

# ── 2. Build ─────────────────────────────────────────────────────────────────
echo "[2/4] Building..."
pnpm build

# ── 3. Check auth ────────────────────────────────────────────────────────────
echo "[3/4] Checking registry auth..."
# Verify we can reach the registry
if ! npm ping --registry "$REGISTRY" 2>/dev/null; then
    echo ""
    echo "Cannot reach $REGISTRY"
    echo "Make sure Verdaccio is running and accessible."
    echo ""
    echo "If you haven't created a user yet, run:"
    echo "  npm adduser --registry $REGISTRY"
    exit 1
fi

# Check if we have a token for this registry
if ! npm whoami --registry "$REGISTRY" 2>/dev/null; then
    echo ""
    echo "Not authenticated. Creating user..."
    npm adduser --registry "$REGISTRY"
fi

echo "  Authenticated as: $(npm whoami --registry "$REGISTRY")"

# ── 4. Publish ───────────────────────────────────────────────────────────────
echo "[4/4] Publishing..."

# Read current version
VERSION=$(node -p "require('./package.json').version")
echo "  Version: $VERSION"

# Publish (--access public needed for scoped packages; harmless for unscoped)
npm publish --registry "$REGISTRY" --access public

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Published openclaw@$VERSION to $REGISTRY"
echo ""
echo "  Install on Raspberry Pi:"
echo "    npm install -g openclaw --registry $REGISTRY"
echo ""
echo "  Or set registry permanently on Pi:"
echo "    npm config set registry $REGISTRY"
echo "    npm install -g openclaw"
echo "════════════════════════════════════════════════════════════"
