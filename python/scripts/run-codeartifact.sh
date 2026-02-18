#!/bin/bash
set -euo pipefail

# Run the Flask app using the CodeArtifact venv
#
# Usage:
#   ./scripts/run-codeartifact.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/.venv-codeartifact"

if [[ ! -d "$VENV_DIR" ]]; then
    echo "Error: CodeArtifact venv not found at $VENV_DIR"
    echo "Run ./scripts/install-codeartifact.sh first"
    exit 1
fi

echo "=========================================="
echo "Running app with CodeArtifact dependencies"
echo "=========================================="

source "$VENV_DIR/bin/activate"

FLASK_VERSION=$(python -c 'import flask; print(flask.__version__)')
echo "Flask version: $FLASK_VERSION"
echo "Starting server at http://localhost:5000"
echo ""

python "$PROJECT_DIR/app.py"
