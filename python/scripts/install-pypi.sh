#!/bin/bash
set -euo pipefail

# Install dependencies from public PyPI into .venv-pypi
#
# Usage:
#   ./scripts/install-pypi.sh
#
# Optional:
#   REQUIREMENTS_FILE=requirements.txt  # Path to requirements file
#   PYTHON=python3                      # Python executable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-$PROJECT_DIR/requirements.txt}"
PYTHON="${PYTHON:-python3}"
VENV_DIR="$PROJECT_DIR/.venv-pypi"

echo "=========================================="
echo "Installing from PyPI"
echo "=========================================="
echo "Requirements: $REQUIREMENTS_FILE"
echo "Venv: $VENV_DIR"
echo ""

# Create fresh venv
if [[ -d "$VENV_DIR" ]]; then
    echo "Removing existing venv..."
    rm -rf "$VENV_DIR"
fi

echo "Creating virtual environment..."
"$PYTHON" -m venv "$VENV_DIR"

# Activate and install
source "$VENV_DIR/bin/activate"

echo "Upgrading pip..."
pip install --upgrade pip --quiet

echo "Installing dependencies from PyPI..."
pip install -r "$REQUIREMENTS_FILE"

echo ""
echo "=========================================="
echo "Installation Complete"
echo "=========================================="
echo "Flask version: $(python -c 'import flask; print(flask.__version__)')"
echo ""
echo "To activate this environment:"
echo "  source $VENV_DIR/bin/activate"
echo ""
echo "To run the app:"
echo "  ./scripts/run-pypi.sh"
