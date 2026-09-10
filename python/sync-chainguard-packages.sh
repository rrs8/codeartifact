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
UPLOADED_FILE="${UPLOADED_FILE:-.codeartifact-uploaded.txt}"

# Target platform for wheels (unset = use sync host's current Python/platform).
# Set these to make the mirror useful for consumers running a different Python
# version/platform than the sync host (common: sync on macOS dev box, consume
# on Linux containers). Falls back to sdist if no matching wheel is available.
#   e.g. TARGET_PYTHON_VERSION=3.11 TARGET_PLATFORM=manylinux2014_x86_64
TARGET_PYTHON_VERSION="${TARGET_PYTHON_VERSION:-}"
TARGET_PLATFORM="${TARGET_PLATFORM:-manylinux2014_x86_64}"

# After sync, automatically flip synced packages from upstream=BLOCK to
# upstream=ALLOW so versions Chainguard doesn't build fall through to
# public PyPI. Set to "0" to skip (keep strict "CG-or-bust" enforcement).
POST_SYNC_ALLOW_UPSTREAM="${POST_SYNC_ALLOW_UPSTREAM:-1}"

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

    local download_output
    download_output=$(mktemp)

    local -a base_args=(
        "$pip_spec"
        --index-url "$index_url"
        --no-deps
        --dest "$WORK_DIR"
    )

    # First attempt: if a target platform/Python is configured, request only a
    # wheel matching that target. Ensures mirror caches deployment-ready wheels
    # (not sync-host-specific ones) for consumers like Linux containers.
    if [[ -n "$TARGET_PYTHON_VERSION" ]]; then
        local target_abi="cp${TARGET_PYTHON_VERSION//./}"
        local -a target_args=(
            --python-version "$TARGET_PYTHON_VERSION"
            --platform "$TARGET_PLATFORM"
            --implementation cp
            --abi "$target_abi"
            --only-binary=:all:
        )

        if pip download "${base_args[@]}" "${target_args[@]}" \
                > "$download_output" 2>&1; then
            rm -f "$download_output"
            return 0
        fi
        # Target wheel unavailable (e.g. pure-Python pkg with sdist only).
        # Fall through to unconstrained download below.
        echo "    No wheel for target ${TARGET_PYTHON_VERSION}/${TARGET_PLATFORM}; falling back to sdist/any..."
    fi

    # Second attempt (or default when no target set): let pip pick anything
    # that satisfies the spec, including sdists.
    if pip download "${base_args[@]}" > "$download_output" 2>&1; then
        rm -f "$download_output"
        return 0
    fi

    # Surface the pip error so failures are debuggable
    echo "    pip download failed:"
    sed 's/^/      /' "$download_output" | tail -10
    rm -f "$download_output"
    return 1
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

    # Set package origin controls: publish=ALLOW, upstream=BLOCK during the sync.
    #
    # Why BLOCK during upload:
    #   twine/pip/npm may trigger a pre-publish metadata GET on the repository.
    #   If upstream=ALLOW, CodeArtifact proxies that GET to public PyPI/npm,
    #   caches the upstream's identical version, and then rejects our publish
    #   with 409 "Package Version X exists in externally connected repository".
    #   BLOCK prevents the proxy, so the publish succeeds and CG's rebuild
    #   becomes the local-origin version.
    #
    # After the sync finishes, run update-codeartifact-origins.sh to flip all
    # uploaded packages to upstream=ALLOW, which lets versions CG didn't
    # build fall through to the upstream repository.
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

    # Note: --skip-existing is NOT supported by AWS CodeArtifact PyPI repositories
    # (twine returns UnsupportedConfiguration). Instead, we detect "already exists"
    # from the error output and treat it as a success.
    if TWINE_USERNAME="$TWINE_USERNAME" TWINE_PASSWORD="$TWINE_PASSWORD" \
        twine upload \
        --repository-url "$CODEARTIFACT_ENDPOINT" \
        "${found_files[@]}" > "$upload_output" 2>&1; then
        echo "$normalized_name" >> "$UPLOADED_FILE"
        rm -f "$upload_output"
        return 0
    else
        if grep -qiE "already exists|HTTPError: 409|Conflict" "$upload_output"; then
            echo "    Package version already exists in CodeArtifact (OK)"
            echo "$normalized_name" >> "$UPLOADED_FILE"
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

# Phase 2: flip upstream=BLOCK -> upstream=ALLOW for all uploaded packages so
# versions Chainguard didn't build fall through to public PyPI via the upstream.
flip_origins_to_allow() {
    if [[ ! -s "$UPLOADED_FILE" ]]; then
        echo "No uploaded packages to flip."
        return 0
    fi
    local count ok=0 failed=0
    count=$(wc -l < "$UPLOADED_FILE" | tr -d ' ')
    echo ""
    echo "Flipping origin controls to upstream=ALLOW for $count uploaded packages..."
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if aws codeartifact put-package-origin-configuration \
            --domain "$DOMAIN_NAME" \
            --repository "$REPO_NAME" \
            --format pypi \
            --package "$pkg" \
            --restrictions "publish=ALLOW,upstream=ALLOW" \
            --region "$AWS_REGION" \
            > /dev/null 2>&1; then
            ok=$((ok + 1))
        else
            failed=$((failed + 1))
            echo "  WARN: failed to flip origin for $pkg"
        fi
    done < "$UPLOADED_FILE"
    echo "  Flipped: $ok, Failed: $failed"
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

# Reset uploaded-tracker file (used for phase 2 origin flip)
: > "$UPLOADED_FILE"

# Counters
FOUND_REMEDIATED=0
FOUND_REGULAR=0
NOT_FOUND_COUNT=0
FAILED_DOWNLOAD_COUNT=0   # pip download failed (version miss, build fail, network)
FAILED_UPLOAD_COUNT=0     # twine upload failed after successful download

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
            FAILED_DOWNLOAD_COUNT=$((FAILED_DOWNLOAD_COUNT + 1))
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

# Phase 2: flip origins from BLOCK -> ALLOW so upstream fallback works for
# versions we didn't sync. Skippable via POST_SYNC_ALLOW_UPSTREAM=0.
if [[ "$POST_SYNC_ALLOW_UPSTREAM" == "1" ]]; then
    flip_origins_to_allow
else
    echo ""
    echo "Skipping origin flip (POST_SYNC_ALLOW_UPSTREAM=0)."
    echo "Synced packages remain at upstream=BLOCK — upstream fallback disabled."
fi

TOTAL_FAILED=$((FAILED_DOWNLOAD_COUNT + FAILED_UPLOAD_COUNT))

echo ""
echo "=========================================="
echo "Sync Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Total packages:                $TOTAL_PACKAGES"
echo "  Found in python-remediated:    $FOUND_REMEDIATED"
echo "  Found in python:               $FOUND_REGULAR"
echo "  Not found (PyPI fallback):     $NOT_FOUND_COUNT"
echo "  Failed to sync:                $TOTAL_FAILED"
echo "    Download failed (version miss, build fail): $FAILED_DOWNLOAD_COUNT"
echo "    Upload failed (twine/CodeArtifact):         $FAILED_UPLOAD_COUNT"
echo ""
echo "Packages not found in Chainguard are recorded in: $NOT_FOUND_FILE"
echo "These packages will be pulled from public PyPI via the CodeArtifact fallback."
