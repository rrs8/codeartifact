#!/bin/bash
set -euo pipefail

# Sync Chainguard packages to AWS CodeArtifact
# Reads package-lock.json, attempts to pull from Chainguard libraries,
# and publishes found packages to CodeArtifact. Not-found packages are
# recorded to a file (they will fall back to public NPM).

# Configuration
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-npm-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-npm-repo}"
LOCKFILE="${LOCKFILE:-package-lock.json}"
WORK_DIR="${WORK_DIR:-.codeartifact-sync}"
NOT_FOUND_FILE="${NOT_FOUND_FILE:-chainguard-not-found.txt}"

# Chainguard configuration (expects CGR_USERNAME and CGR_TOKEN env vars)
CGR_REGISTRY="https://libraries.cgr.dev/javascript/"

# Validate required environment variables
if [[ -z "${CGR_USERNAME:-}" ]]; then
    echo "Error: CGR_USERNAME environment variable is required"
    exit 1
fi

if [[ -z "${CGR_TOKEN:-}" ]]; then
    echo "Error: CGR_TOKEN environment variable is required"
    exit 1
fi

# Check for required tools
for cmd in jq aws npm; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

# Check if lockfile exists
if [[ ! -f "$LOCKFILE" ]]; then
    echo "Error: Lockfile '$LOCKFILE' not found."
    exit 1
fi

echo "=========================================="
echo "Chainguard to CodeArtifact Sync"
echo "=========================================="
echo "Lockfile: $LOCKFILE"
echo "AWS Region: $AWS_REGION"
echo "CodeArtifact Domain: $DOMAIN_NAME"
echo "CodeArtifact Repo: $REPO_NAME"
echo ""

# Create work directory
mkdir -p "$WORK_DIR"

# Initialize not-found file
echo "# Packages not found in Chainguard libraries" > "$NOT_FOUND_FILE"
echo "# These will be pulled from public NPM via CodeArtifact fallback" >> "$NOT_FOUND_FILE"
echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$NOT_FOUND_FILE"
echo "" >> "$NOT_FOUND_FILE"

# Get CodeArtifact auth token
echo "Obtaining CodeArtifact auth token..."
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

# Extract packages from lockfile
# Handles lockfileVersion 2 and 3 format (packages object)
echo "Extracting packages from lockfile..."
PACKAGES=$(jq -r '
    .packages // {} |
    to_entries |
    map(select(.key != "" and .key != null and (.key | startswith("node_modules/")))) |
    map({
        name: (.key | sub("^node_modules/"; "")),
        version: .value.version
    }) |
    .[] |
    "\(.name)@\(.version)"
' "$LOCKFILE")

if [[ -z "$PACKAGES" ]]; then
    echo "No packages found in lockfile."
    exit 0
fi

TOTAL_PACKAGES=$(echo "$PACKAGES" | wc -l | tr -d ' ')
echo "Found $TOTAL_PACKAGES packages to process"
echo ""

# Counters
FOUND_COUNT=0
NOT_FOUND_COUNT=0
FAILED_PUBLISH_COUNT=0

# Process each package
echo "Processing packages..."
echo ""

while IFS= read -r PACKAGE; do
    [[ -z "$PACKAGE" ]] && continue

    PACKAGE_NAME=$(echo "$PACKAGE" | sed 's/@[^@]*$//')
    PACKAGE_VERSION=$(echo "$PACKAGE" | grep -o '@[^@]*$' | sed 's/@//')

    echo "----------------------------------------"
    echo "Processing: $PACKAGE_NAME@$PACKAGE_VERSION"

    # Clean work directory
    rm -f "$WORK_DIR"/*.tgz

    # Try to fetch from Chainguard
    echo "  Fetching from Chainguard..."

    # Create temporary npmrc for Chainguard auth
    CGR_NPMRC=$(mktemp)
    cat > "$CGR_NPMRC" <<EOF
//libraries.cgr.dev/:username=$CGR_USERNAME
//libraries.cgr.dev/:_password=$(echo -n "$CGR_TOKEN" | base64)
always-auth=true
EOF

    NPM_EXIT_CODE=0
    npm pack "$PACKAGE_NAME@$PACKAGE_VERSION" \
        --registry="$CGR_REGISTRY" \
        --userconfig "$CGR_NPMRC" \
        --pack-destination "$WORK_DIR" \
        > /dev/null 2>&1 || NPM_EXIT_CODE=$?

    if [[ $NPM_EXIT_CODE -eq 0 ]]; then
        echo "  Found in Chainguard!"
        FOUND_COUNT=$((FOUND_COUNT + 1))

        # Find the downloaded tarball
        TARBALL=$(ls -1 "$WORK_DIR"/*.tgz 2>/dev/null | head -n1)

        if [[ -n "$TARBALL" && -f "$TARBALL" ]]; then
            echo "  Publishing to CodeArtifact..."

            # Set package origin controls to allow direct publish and block upstream
            # This ensures Chainguard packages take precedence over public NPM
            echo "  Configuring package origin controls..."

            # Handle scoped packages (@scope/name) vs unscoped packages
            if [[ "$PACKAGE_NAME" == @*/* ]]; then
                # Scoped package: extract namespace and package name
                PKG_NAMESPACE=$(echo "$PACKAGE_NAME" | sed 's|^@||' | cut -d'/' -f1)
                PKG_SHORT_NAME=$(echo "$PACKAGE_NAME" | cut -d'/' -f2)
                aws codeartifact put-package-origin-configuration \
                    --domain "$DOMAIN_NAME" \
                    --repository "$REPO_NAME" \
                    --format npm \
                    --namespace "$PKG_NAMESPACE" \
                    --package "$PKG_SHORT_NAME" \
                    --restrictions "publish=ALLOW,upstream=BLOCK" \
                    --region "$AWS_REGION" \
                    > /dev/null 2>&1 || true
            else
                # Unscoped package
                aws codeartifact put-package-origin-configuration \
                    --domain "$DOMAIN_NAME" \
                    --repository "$REPO_NAME" \
                    --format npm \
                    --package "$PACKAGE_NAME" \
                    --restrictions "publish=ALLOW,upstream=BLOCK" \
                    --region "$AWS_REGION" \
                    > /dev/null 2>&1 || true
            fi

            # Create temporary npmrc for CodeArtifact auth
            CA_NPMRC=$(mktemp)
            # Extract path from endpoint for npmrc (keep trailing slash for auth)
            CA_PATH=$(echo "$CODEARTIFACT_ENDPOINT" | sed 's|https://||')
            # Ensure trailing slash
            [[ "$CA_PATH" != */ ]] && CA_PATH="${CA_PATH}/"
            cat > "$CA_NPMRC" <<EOF
//${CA_PATH}:_authToken=$CODEARTIFACT_AUTH_TOKEN
registry=$CODEARTIFACT_ENDPOINT
EOF

            PUBLISH_OUTPUT=$(mktemp)
            PUBLISH_EXIT_CODE=0
            npm publish "$TARBALL" \
                --registry="$CODEARTIFACT_ENDPOINT" \
                --userconfig "$CA_NPMRC" \
                > "$PUBLISH_OUTPUT" 2>&1 || PUBLISH_EXIT_CODE=$?

            if [[ $PUBLISH_EXIT_CODE -eq 0 ]]; then
                echo "  Successfully published to CodeArtifact!"
            elif grep -q "already exists\|EPUBLISHCONFLICT\|previously published versions" "$PUBLISH_OUTPUT"; then
                echo "  Package already exists in CodeArtifact (OK)"
            else
                echo "  Warning: Failed to publish to CodeArtifact"
                echo "  Error details:"
                cat "$PUBLISH_OUTPUT"
                FAILED_PUBLISH_COUNT=$((FAILED_PUBLISH_COUNT + 1))
            fi

            rm -f "$CA_NPMRC" "$PUBLISH_OUTPUT"
        else
            echo "  Warning: Tarball not found after pack"
            FAILED_PUBLISH_COUNT=$((FAILED_PUBLISH_COUNT + 1))
        fi
    else
        echo "  Not found in Chainguard - will use NPM fallback"
        NOT_FOUND_COUNT=$((NOT_FOUND_COUNT + 1))
        echo "$PACKAGE_NAME@$PACKAGE_VERSION" >> "$NOT_FOUND_FILE"
    fi

    rm -f "$CGR_NPMRC"

done <<< "$PACKAGES"

# Clean up
rm -rf "$WORK_DIR"

echo ""
echo "=========================================="
echo "Sync Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Total packages:           $TOTAL_PACKAGES"
echo "  Found in Chainguard:      $FOUND_COUNT"
echo "  Not found (NPM fallback): $NOT_FOUND_COUNT"
echo "  Failed to publish:        $FAILED_PUBLISH_COUNT"
echo ""
echo "Packages not found in Chainguard are recorded in: $NOT_FOUND_FILE"
echo "These packages will be pulled from public NPM via the CodeArtifact fallback."
