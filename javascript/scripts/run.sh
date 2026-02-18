#!/bin/bash
set -euo pipefail

# Run the Node.js server
#
# Usage:
#   ./scripts/run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

if [[ ! -d "node_modules" ]]; then
    echo "Error: node_modules not found"
    echo "Run ./scripts/install-npm.sh or ./scripts/install-codeartifact.sh first"
    exit 1
fi

echo "=========================================="
echo "Running Node.js app"
echo "=========================================="

# Show a few key package versions
echo "Key packages installed:"
for pkg in express lodash axios chalk; do
    if [[ -f "node_modules/$pkg/package.json" ]]; then
        version=$(node -p "require('./node_modules/$pkg/package.json').version" 2>/dev/null || echo "not found")
        echo "  $pkg: $version"
    fi
done
echo ""

echo "Starting server at http://localhost:${PORT:-5002}"
echo ""

node server.js
