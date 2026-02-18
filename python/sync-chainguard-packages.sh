#!/bin/bash
set -euo pipefail

# Sync Chainguard packages to AWS CodeArtifact
# Reads requirements.txt, checks Chainguard libraries (remediated first, then regular),
# and publishes found packages to CodeArtifact. Not-found packages are
# recorded to a file (they will fall back to public PyPI).

# Configuration
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-pypi-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-pypi-repo}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-requirements.txt}"
WORK_DIR="${WORK_DIR:-.codeartifact-sync}"
NOT_FOUND_FILE="${NOT_FOUND_FILE:-chainguard-not-found.txt}"

# Chainguard configuration
# Auth credentials should be in ~/.netrc, but can be overridden with env vars
CGR_REMEDIATED_INDEX="${CGR_REMEDIATED_INDEX:-https://libraries.cgr.dev/python-remediated/simple/}"
CGR_PYTHON_INDEX="${CGR_PYTHON_INDEX:-https://libraries.cgr.dev/python/simple/}"

# Check for required tools
for cmd in pip twine aws; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

# Check if requirements file exists
if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
    echo "Error: Requirements file '$REQUIREMENTS_FILE' not found."
    exit 1
fi

echo "=========================================="
echo "Chainguard to CodeArtifact Sync (Python)"
echo "=========================================="
echo "Requirements file: $REQUIREMENTS_FILE"
echo "AWS Region: $AWS_REGION"
echo "CodeArtifact Domain: $DOMAIN_NAME"
echo "CodeArtifact Repo: $REPO_NAME"
echo ""

# Create work directory
mkdir -p "$WORK_DIR"

# Initialize not-found file
echo "# Packages not found in Chainguard libraries" > "$NOT_FOUND_FILE"
echo "# These will be pulled from public PyPI via CodeArtifact fallback" >> "$NOT_FOUND_FILE"
echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$NOT_FOUND_FILE"
echo "" >> "$NOT_FOUND_FILE"

# Get CodeArtifact auth token and endpoint
echo "Obtaining CodeArtifact credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

TWINE_USERNAME="aws"
TWINE_PASSWORD=$(aws codeartifact get-authorization-token \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" \
    --query 'authorizationToken' \
    --output text)

CODEARTIFACT_ENDPOINT=$(aws codeartifact get-repository-endpoint \
    --domain "$DOMAIN_NAME" \
    --repository "$REPO_NAME" \
    --format pypi \
    --region "$AWS_REGION" \
    --query 'repositoryEndpoint' \
    --output text)

echo "CodeArtifact endpoint: $CODEARTIFACT_ENDPOINT"
echo ""

# Parse requirements.txt and extract package specs
# Handles: package==version, package>=version, package~=version, package (no version)
# Ignores: comments (#), blank lines, -r includes, -e editable installs, URLs
parse_requirements() {
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines, comments, -r/-e/-i flags, and URLs
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        [[ "$line" =~ ^-[rei] ]] && continue
        [[ "$line" =~ ^https?:// ]] && continue
        [[ "$line" =~ ^git\+ ]] && continue

        # Extract package name and version
        # Handle various specifiers: ==, >=, <=, ~=, !=, >, <
        if [[ "$line" =~ ^([a-zA-Z0-9_-]+(\[[a-zA-Z0-9_,-]+\])?)[[:space:]]*(==|>=|<=|~=|!=|>|<)(.+)$ ]]; then
            pkg_name="${BASH_REMATCH[1]}"
            version_spec="${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
            # Remove extras brackets for package name lookup
            pkg_name_clean=$(echo "$pkg_name" | sed 's/\[.*\]//')
            echo "$pkg_name_clean $version_spec"
        elif [[ "$line" =~ ^([a-zA-Z0-9_-]+(\[[a-zA-Z0-9_,-]+\])?)$ ]]; then
            # Package without version
            pkg_name="${BASH_REMATCH[1]}"
            pkg_name_clean=$(echo "$pkg_name" | sed 's/\[.*\]//')
            echo "$pkg_name_clean"
        fi
    done < "$REQUIREMENTS_FILE"
}

# Check if package exists in a Chainguard index
check_chainguard_index() {
    local pkg_name="$1"
    local index_url="$2"
    local index_name="$3"

    # Normalize package name (PEP 503: lowercase, replace _ with -)
    local normalized_name=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    # Check if package page exists in the index
    local pkg_url="${index_url}${normalized_name}/"

    # Use curl with netrc for auth
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --netrc "$pkg_url" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

# Download package from Chainguard index
download_from_chainguard() {
    local pkg_name="$1"
    local version_spec="$2"
    local index_url="$3"

    # Clean the work directory
    rm -f "$WORK_DIR"/*.whl "$WORK_DIR"/*.tar.gz

    local pip_spec="$pkg_name"
    if [[ -n "$version_spec" ]]; then
        pip_spec="${pkg_name}${version_spec}"
    fi

    # Download using pip with the Chainguard index
    if pip download "$pip_spec" \
        --index-url "$index_url" \
        --no-deps \
        --dest "$WORK_DIR" \
        > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Upload package to CodeArtifact
upload_to_codeartifact() {
    local pkg_name="$1"

    # Find downloaded files
    local files=("$WORK_DIR"/*.whl "$WORK_DIR"/*.tar.gz)
    local found_files=()
    for f in "${files[@]}"; do
        [[ -f "$f" ]] && found_files+=("$f")
    done

    if [[ ${#found_files[@]} -eq 0 ]]; then
        echo "    Warning: No files found to upload"
        return 1
    fi

    # Set package origin controls to allow direct publish and block upstream
    # Normalize package name for AWS API
    local normalized_name=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    echo "    Configuring package origin controls..."
    aws codeartifact put-package-origin-configuration \
        --domain "$DOMAIN_NAME" \
        --repository "$REPO_NAME" \
        --format pypi \
        --package "$normalized_name" \
        --restrictions "publish=ALLOW,upstream=BLOCK" \
        --region "$AWS_REGION" \
        > /dev/null 2>&1 || true

    # Upload with twine
    echo "    Uploading to CodeArtifact..."
    local upload_output
    upload_output=$(mktemp)

    if TWINE_USERNAME="$TWINE_USERNAME" TWINE_PASSWORD="$TWINE_PASSWORD" \
        twine upload \
        --repository-url "$CODEARTIFACT_ENDPOINT" \
        --skip-existing \
        "${found_files[@]}" > "$upload_output" 2>&1; then
        rm -f "$upload_output"
        return 0
    else
        if grep -qi "already exists\|skipping" "$upload_output"; then
            echo "    Package version already exists in CodeArtifact (OK)"
            rm -f "$upload_output"
            return 0
        else
            echo "    Warning: Upload failed"
            cat "$upload_output"
            rm -f "$upload_output"
            return 1
        fi
    fi
}

# Extract packages from requirements file
echo "Parsing requirements file..."
PACKAGES=$(parse_requirements)

if [[ -z "$PACKAGES" ]]; then
    echo "No packages found in requirements file."
    exit 0
fi

TOTAL_PACKAGES=$(echo "$PACKAGES" | wc -l | tr -d ' ')
echo "Found $TOTAL_PACKAGES packages to process"
echo ""

# Counters
FOUND_REMEDIATED=0
FOUND_REGULAR=0
NOT_FOUND_COUNT=0
FAILED_UPLOAD_COUNT=0

# Process each package
echo "Processing packages..."
echo ""

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Parse package name and version spec
    read -r pkg_name version_spec <<< "$line"

    echo "----------------------------------------"
    if [[ -n "$version_spec" ]]; then
        echo "Processing: $pkg_name ($version_spec)"
    else
        echo "Processing: $pkg_name (latest)"
    fi

    # Try python-remediated first
    echo "  Checking python-remediated index..."
    if check_chainguard_index "$pkg_name" "$CGR_REMEDIATED_INDEX" "remediated"; then
        echo "  Found in python-remediated!"

        if download_from_chainguard "$pkg_name" "$version_spec" "$CGR_REMEDIATED_INDEX"; then
            if upload_to_codeartifact "$pkg_name"; then
                echo "  Successfully synced from python-remediated!"
                FOUND_REMEDIATED=$((FOUND_REMEDIATED + 1))
                continue
            else
                FAILED_UPLOAD_COUNT=$((FAILED_UPLOAD_COUNT + 1))
                continue
            fi
        else
            echo "  Warning: Found in index but download failed, trying regular python..."
        fi
    fi

    # Try regular python index
    echo "  Checking python index..."
    if check_chainguard_index "$pkg_name" "$CGR_PYTHON_INDEX" "python"; then
        echo "  Found in python!"

        if download_from_chainguard "$pkg_name" "$version_spec" "$CGR_PYTHON_INDEX"; then
            if upload_to_codeartifact "$pkg_name"; then
                echo "  Successfully synced from python!"
                FOUND_REGULAR=$((FOUND_REGULAR + 1))
                continue
            else
                FAILED_UPLOAD_COUNT=$((FAILED_UPLOAD_COUNT + 1))
                continue
            fi
        else
            echo "  Warning: Found in index but download failed"
            FAILED_UPLOAD_COUNT=$((FAILED_UPLOAD_COUNT + 1))
            continue
        fi
    fi

    # Not found in either index
    echo "  Not found in Chainguard - will use PyPI fallback"
    NOT_FOUND_COUNT=$((NOT_FOUND_COUNT + 1))
    if [[ -n "$version_spec" ]]; then
        echo "${pkg_name}${version_spec}" >> "$NOT_FOUND_FILE"
    else
        echo "$pkg_name" >> "$NOT_FOUND_FILE"
    fi

done <<< "$PACKAGES"

# Clean up
rm -rf "$WORK_DIR"

echo ""
echo "=========================================="
echo "Sync Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Total packages:              $TOTAL_PACKAGES"
echo "  Found in python-remediated:  $FOUND_REMEDIATED"
echo "  Found in python:             $FOUND_REGULAR"
echo "  Not found (PyPI fallback):   $NOT_FOUND_COUNT"
echo "  Failed to upload:            $FAILED_UPLOAD_COUNT"
echo ""
echo "Packages not found in Chainguard are recorded in: $NOT_FOUND_FILE"
echo "These packages will be pulled from public PyPI via the CodeArtifact fallback."
