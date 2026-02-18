#!/bin/bash
set -euo pipefail

# Build and install dependencies from AWS CodeArtifact
#
# Usage:
#   ./scripts/install-codeartifact.sh
#
# Required environment variables:
#   AWS_REGION                    # AWS region (or uses default us-east-2)
#   CODEARTIFACT_DOMAIN           # CodeArtifact domain (or uses default my-maven-domain)
#   CODEARTIFACT_REPO             # CodeArtifact repository (or uses default my-maven-repo)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration - matches setup-codeartifact.sh defaults
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-maven-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-maven-repo}"

echo "=========================================="
echo "Building from CodeArtifact"
echo "=========================================="
echo "AWS Region: $AWS_REGION"
echo "Domain: $DOMAIN_NAME"
echo "Repository: $REPO_NAME"
echo ""

cd "$PROJECT_DIR"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

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
    --domain-owner "$ACCOUNT_ID" \
    --repository "$REPO_NAME" \
    --format maven \
    --region "$AWS_REGION" \
    --query 'repositoryEndpoint' \
    --output text)

echo "CodeArtifact endpoint: $CODEARTIFACT_ENDPOINT"
echo ""

# Create temporary settings.xml with CodeArtifact config
SETTINGS_FILE=$(mktemp)
cat > "$SETTINGS_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <servers>
    <server>
      <id>codeartifact</id>
      <username>aws</username>
      <password>${CODEARTIFACT_AUTH_TOKEN}</password>
    </server>
  </servers>

  <profiles>
    <profile>
      <id>codeartifact</id>
      <repositories>
        <repository>
          <id>codeartifact</id>
          <url>${CODEARTIFACT_ENDPOINT}</url>
          <releases>
            <enabled>true</enabled>
          </releases>
          <snapshots>
            <enabled>true</enabled>
          </snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>

  <activeProfiles>
    <activeProfile>codeartifact</activeProfile>
  </activeProfiles>
</settings>
EOF

# Clean previous build and local repo cache for these dependencies
echo "Cleaning previous build..."
mvn clean -q

# Optionally purge local repo to force re-download from CodeArtifact
# Uncomment if you want to ensure fresh downloads:
# echo "Purging local repository cache..."
# mvn dependency:purge-local-repository -DactTransitively=false -DreResolve=false -q 2>/dev/null || true

# Build with CodeArtifact
echo "Building with CodeArtifact..."
mvn package -DskipTests -s "$SETTINGS_FILE"

# Clean up
rm -f "$SETTINGS_FILE"

echo ""
echo "=========================================="
echo "Build Complete"
echo "=========================================="

# Show dependency versions
echo ""
echo "Dependencies used:"
mvn dependency:list -DincludeScope=runtime -q | grep ":.*:.*:" | sed 's/\[INFO\]//' | sort || true

echo ""
echo "To run the app:"
echo "  ./scripts/run.sh"
