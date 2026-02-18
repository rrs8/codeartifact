#!/bin/bash
set -euo pipefail

# AWS CodeArtifact Cleanup Script for Python/PyPI
# Deletes the CodeArtifact repository, upstream repository, and domain

# Configuration
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-pypi-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-pypi-repo}"
UPSTREAM_REPO_NAME="${CODEARTIFACT_UPSTREAM_REPO:-pypi-public}"

echo "Cleaning up AWS CodeArtifact in region: $AWS_REGION"
echo "Domain: $DOMAIN_NAME"
echo "Repository: $REPO_NAME"
echo "Upstream (public PyPI): $UPSTREAM_REPO_NAME"
echo ""

# Delete the main repository first
echo "Deleting main repository '$REPO_NAME'..."
if aws codeartifact delete-repository \
    --domain "$DOMAIN_NAME" \
    --repository "$REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "Repository '$REPO_NAME' deleted successfully."
else
    echo "Repository '$REPO_NAME' does not exist or deletion failed. Continuing..."
fi

# Delete the upstream repository
echo ""
echo "Deleting upstream repository '$UPSTREAM_REPO_NAME'..."
if aws codeartifact delete-repository \
    --domain "$DOMAIN_NAME" \
    --repository "$UPSTREAM_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "Upstream repository '$UPSTREAM_REPO_NAME' deleted successfully."
else
    echo "Upstream repository '$UPSTREAM_REPO_NAME' does not exist or deletion failed. Continuing..."
fi

# Delete the domain
echo ""
echo "Deleting domain '$DOMAIN_NAME'..."
if aws codeartifact delete-domain \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "Domain '$DOMAIN_NAME' deleted successfully."
else
    echo "Domain '$DOMAIN_NAME' does not exist or deletion failed."
fi

echo ""
echo "=========================================="
echo "CodeArtifact Cleanup Complete!"
echo "=========================================="
