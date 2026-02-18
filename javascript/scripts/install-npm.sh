#!/bin/bash
set -euo pipefail

# Install dependencies from public npm registry
#
# Usage:
#   ./scripts/install-npm.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Installing from public npm"
echo "=========================================="
echo ""

cd "$PROJECT_DIR"

# Clear existing node_modules
if [[ -d "node_modules" ]]; then
    echo "Removing existing node_modules..."
    rm -rf node_modules
fi

# Clear npm cache for clean install
echo "Clearing npm cache..."
npm cache clean --force 2>/dev/null || true

# Remove any custom registry config
echo "Resetting npm registry to default..."
npm config delete registry 2>/dev/null || true

# Install from public npm
echo "Installing dependencies from npm..."
npm install --registry=https://registry.npmjs.org/

echo ""
echo "=========================================="
echo "Installation Complete"
echo "=========================================="

# Show installed versions of key packages
echo ""
echo "Installed packages:"
npm ls --depth=0 2>/dev/null || true

echo ""
echo "To run the app:"
echo "  ./scripts/run.sh"
