#!/bin/bash
set -euo pipefail

# AWS CodeArtifact Setup Script
# Creates a CodeArtifact domain and repository with NPM public registry fallback

# Configuration
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-npm-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-npm-repo}"
UPSTREAM_REPO_NAME="${CODEARTIFACT_UPSTREAM_REPO:-npm-public}"

echo "Setting up AWS CodeArtifact in region: $AWS_REGION"
echo "Domain: $DOMAIN_NAME"
echo "Repository: $REPO_NAME"
echo "Upstream (public NPM): $UPSTREAM_REPO_NAME"
echo ""

# Create the domain
echo "Creating CodeArtifact domain..."
if aws codeartifact create-domain \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "Domain '$DOMAIN_NAME' created successfully."
else
    echo "Domain '$DOMAIN_NAME' already exists or creation failed. Continuing..."
fi

# Create the upstream repository with external connection to public NPM
echo ""
echo "Creating upstream repository with NPM public connection..."
if aws codeartifact create-repository \
    --domain "$DOMAIN_NAME" \
    --repository "$UPSTREAM_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "Upstream repository '$UPSTREAM_REPO_NAME' created successfully."
else
    echo "Upstream repository '$UPSTREAM_REPO_NAME' already exists or creation failed. Continuing..."
fi

# Associate external connection to public NPM
echo ""
echo "Associating external connection to public NPM registry..."
if aws codeartifact associate-external-connection \
    --domain "$DOMAIN_NAME" \
    --repository "$UPSTREAM_REPO_NAME" \
    --external-connection "public:npmjs" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "External connection to public:npmjs associated successfully."
else
    echo "External connection already exists or association failed. Continuing..."
fi

# Create the main repository with upstream fallback
echo ""
echo "Creating main repository with upstream fallback..."
if aws codeartifact create-repository \
    --domain "$DOMAIN_NAME" \
    --repository "$REPO_NAME" \
    --upstreams "repositoryName=$UPSTREAM_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "Main repository '$REPO_NAME' created successfully."
else
    echo "Main repository '$REPO_NAME' already exists. Updating upstreams..."
    aws codeartifact update-repository \
        --domain "$DOMAIN_NAME" \
        --repository "$REPO_NAME" \
        --upstreams "repositoryName=$UPSTREAM_REPO_NAME" \
        --region "$AWS_REGION" || true
fi

# Get repository endpoint
echo ""
echo "Fetching repository endpoint..."
REPO_ENDPOINT=$(aws codeartifact get-repository-endpoint \
    --domain "$DOMAIN_NAME" \
    --repository "$REPO_NAME" \
    --format npm \
    --region "$AWS_REGION" \
    --query 'repositoryEndpoint' \
    --output text)

echo ""
echo "=========================================="
echo "CodeArtifact Setup Complete!"
echo "=========================================="
echo ""
echo "Repository Endpoint: $REPO_ENDPOINT"
echo ""
echo "To configure npm to use this repository, run:"
echo ""
echo "  aws codeartifact login --tool npm \\"
echo "      --domain $DOMAIN_NAME \\"
echo "      --repository $REPO_NAME \\"
echo "      --region $AWS_REGION"
echo ""
echo "Or manually set the registry:"
echo ""
echo "  npm config set registry $REPO_ENDPOINT"
echo ""
echo "Environment variables for other scripts:"
echo "  export CODEARTIFACT_DOMAIN=$DOMAIN_NAME"
echo "  export CODEARTIFACT_REPO=$REPO_NAME"
echo "  export AWS_REGION=$AWS_REGION"
