#!/bin/bash
set -euo pipefail

# Run the Flask app using the PyPI venv
#
# Usage:
#   ./scripts/run-pypi.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/.venv-pypi"

if [[ ! -d "$VENV_DIR" ]]; then
    echo "Error: PyPI venv not found at $VENV_DIR"
    echo "Run ./scripts/install-pypi.sh first"
    exit 1
fi

echo "=========================================="
echo "Running app with PyPI dependencies"
echo "=========================================="

source "$VENV_DIR/bin/activate"

FLASK_VERSION=$(python -c 'import flask; print(flask.__version__)')
echo "Flask version: $FLASK_VERSION"
echo "Starting server at http://localhost:5000"
echo ""

python "$PROJECT_DIR/app.py"
