#!/bin/bash
set -euo pipefail

# Install dependencies from AWS CodeArtifact into .venv-codeartifact
#
# Usage:
#   ./scripts/install-codeartifact.sh
#
# Required environment variables:
#   AWS_REGION                    # AWS region (or uses default us-east-2)
#   CODEARTIFACT_DOMAIN           # CodeArtifact domain (or uses default my-pypi-domain)
#   CODEARTIFACT_REPO             # CodeArtifact repository (or uses default my-pypi-repo)
#
# Optional:
#   REQUIREMENTS_FILE=requirements.txt  # Path to requirements file
#   PYTHON=python3                      # Python executable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration - matches setup-codeartifact.sh defaults
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-pypi-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-pypi-repo}"

REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-$PROJECT_DIR/requirements.txt}"
PYTHON="${PYTHON:-python3}"
VENV_DIR="$PROJECT_DIR/.venv-codeartifact"

echo "=========================================="
echo "Installing from CodeArtifact"
echo "=========================================="
echo "Requirements: $REQUIREMENTS_FILE"
echo "AWS Region: $AWS_REGION"
echo "Domain: $DOMAIN_NAME"
echo "Repository: $REPO_NAME"
echo "Venv: $VENV_DIR"
echo ""

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get CodeArtifact auth token
echo "Obtaining CodeArtifact credentials..."
TOKEN=$(aws codeartifact get-authorization-token \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" \
    --query 'authorizationToken' \
    --output text)

# Get CodeArtifact endpoint
ENDPOINT=$(aws codeartifact get-repository-endpoint \
    --domain "$DOMAIN_NAME" \
    --domain-owner "$ACCOUNT_ID" \
    --repository "$REPO_NAME" \
    --format pypi \
    --region "$AWS_REGION" \
    --query 'repositoryEndpoint' \
    --output text)

# Build pip index URL with embedded credentials
# Format: https://aws:TOKEN@domain-account.d.codeartifact.region.amazonaws.com/pypi/repo/simple/
PIP_INDEX_URL="https://aws:${TOKEN}@${ENDPOINT#https://}simple/"

echo "CodeArtifact endpoint configured"
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

echo "Installing dependencies from CodeArtifact..."
pip install -r "$REQUIREMENTS_FILE" --index-url "$PIP_INDEX_URL"

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
echo "  ./scripts/run-codeartifact.sh"
