#!/bin/bash
set -euo pipefail

# Install dependencies from AWS CodeArtifact
#
# Usage:
#   ./scripts/install-codeartifact.sh
#
# Required environment variables:
#   AWS_REGION                    # AWS region (or uses default us-east-2)
#   CODEARTIFACT_DOMAIN           # CodeArtifact domain (or uses default my-npm-domain)
#   CODEARTIFACT_REPO             # CodeArtifact repository (or uses default my-npm-repo)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration - matches setup-codeartifact.sh defaults
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-npm-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-npm-repo}"

echo "=========================================="
echo "Installing from CodeArtifact"
echo "=========================================="
echo "AWS Region: $AWS_REGION"
echo "Domain: $DOMAIN_NAME"
echo "Repository: $REPO_NAME"
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

# Get CodeArtifact auth token
echo "Obtaining CodeArtifact credentials..."
CODEARTIFACT_AUTH_TOKEN=$(aws codeartifact get-authorization-token \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" \
    --query 'authorizationToken' \
    --output text)

# Get CodeArtifact endpoint
CODEARTIFACT_ENDPOINT=$(aws codeartifact get-repository-endpoint \
    --domain "$DOMAIN_NAME" \
    --repository "$REPO_NAME" \
    --format npm \
    --region "$AWS_REGION" \
    --query 'repositoryEndpoint' \
    --output text)

echo "CodeArtifact endpoint: $CODEARTIFACT_ENDPOINT"
echo ""

# Create temporary .npmrc with CodeArtifact auth
# Extract the registry path for auth config
REGISTRY_PATH=$(echo "$CODEARTIFACT_ENDPOINT" | sed 's|https://||')

# Backup existing .npmrc if present
if [[ -f ".npmrc" ]]; then
    cp .npmrc .npmrc.backup
fi

# Create .npmrc with CodeArtifact config
cat > .npmrc <<EOF
registry=${CODEARTIFACT_ENDPOINT}
//${REGISTRY_PATH}:_authToken=${CODEARTIFACT_AUTH_TOKEN}
//${REGISTRY_PATH}:always-auth=true
EOF

echo "Installing dependencies from CodeArtifact..."
npm install

# Restore original .npmrc if there was one, otherwise remove
if [[ -f ".npmrc.backup" ]]; then
    mv .npmrc.backup .npmrc
else
    rm -f .npmrc
fi

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
