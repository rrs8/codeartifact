#!/bin/bash
set -euo pipefail

# AWS CodeArtifact Setup Script for Java/Maven
# Creates a CodeArtifact domain and repository with Maven Central fallback

# Configuration
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-maven-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-maven-repo}"
UPSTREAM_REPO_NAME="${CODEARTIFACT_UPSTREAM_REPO:-maven-central-public}"

echo "Setting up AWS CodeArtifact in region: $AWS_REGION"
echo "Domain: $DOMAIN_NAME"
echo "Repository: $REPO_NAME"
echo "Upstream (Maven Central): $UPSTREAM_REPO_NAME"
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

# Create the upstream repository with external connection to Maven Central
echo ""
echo "Creating upstream repository with Maven Central connection..."
if aws codeartifact create-repository \
    --domain "$DOMAIN_NAME" \
    --repository "$UPSTREAM_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "Upstream repository '$UPSTREAM_REPO_NAME' created successfully."
else
    echo "Upstream repository '$UPSTREAM_REPO_NAME' already exists or creation failed. Continuing..."
fi

# Associate external connection to Maven Central
echo ""
echo "Associating external connection to Maven Central..."
if aws codeartifact associate-external-connection \
    --domain "$DOMAIN_NAME" \
    --repository "$UPSTREAM_REPO_NAME" \
    --external-connection "public:maven-central" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "External connection to public:maven-central associated successfully."
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
    --format maven \
    --region "$AWS_REGION" \
    --query 'repositoryEndpoint' \
    --output text)

# Get authorization token
AUTH_TOKEN=$(aws codeartifact get-authorization-token \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" \
    --query 'authorizationToken' \
    --output text)

echo ""
echo "=========================================="
echo "CodeArtifact Setup Complete!"
echo "=========================================="
echo ""
echo "Repository Endpoint: $REPO_ENDPOINT"
echo ""
echo "To configure Maven, add this to your ~/.m2/settings.xml:"
echo ""
echo "  <servers>"
echo "    <server>"
echo "      <id>codeartifact</id>"
echo "      <username>aws</username>"
echo "      <password>\${env.CODEARTIFACT_AUTH_TOKEN}</password>"
echo "    </server>"
echo "  </servers>"
echo ""
echo "  <profiles>"
echo "    <profile>"
echo "      <id>codeartifact</id>"
echo "      <repositories>"
echo "        <repository>"
echo "          <id>codeartifact</id>"
echo "          <url>$REPO_ENDPOINT</url>"
echo "        </repository>"
echo "      </repositories>"
echo "    </profile>"
echo "  </profiles>"
echo ""
echo "  <activeProfiles>"
echo "    <activeProfile>codeartifact</activeProfile>"
echo "  </activeProfiles>"
echo ""
echo "Then set the auth token:"
echo ""
echo "  export CODEARTIFACT_AUTH_TOKEN=\$(aws codeartifact get-authorization-token \\"
echo "      --domain $DOMAIN_NAME --region $AWS_REGION \\"
echo "      --query authorizationToken --output text)"
echo ""
echo "Environment variables for other scripts:"
echo "  export CODEARTIFACT_DOMAIN=$DOMAIN_NAME"
echo "  export CODEARTIFACT_REPO=$REPO_NAME"
echo "  export AWS_REGION=$AWS_REGION"
