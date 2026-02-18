#!/bin/bash
set -euo pipefail

# Sync Chainguard packages to AWS CodeArtifact
# Reads pom.xml, checks Chainguard Java libraries,
# and publishes found packages to CodeArtifact. Not-found packages are
# recorded to a file (they will fall back to Maven Central).

# Configuration
AWS_REGION="${AWS_REGION:-us-east-2}"
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-my-maven-domain}"
REPO_NAME="${CODEARTIFACT_REPO:-my-maven-repo}"
POM_FILE="${POM_FILE:-pom.xml}"
WORK_DIR="${WORK_DIR:-.codeartifact-sync}"
NOT_FOUND_FILE="${NOT_FOUND_FILE:-chainguard-not-found.txt}"

# Chainguard configuration
# Auth credentials should be in ~/.netrc
CGR_MAVEN_INDEX="${CGR_MAVEN_INDEX:-https://libraries.cgr.dev/java/}"

# Check for required tools
for cmd in aws curl mvn; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

# Check if pom.xml exists
if [[ ! -f "$POM_FILE" ]]; then
    echo "Error: POM file '$POM_FILE' not found."
    exit 1
fi

echo "=========================================="
echo "Chainguard to CodeArtifact Sync (Java)"
echo "=========================================="
echo "POM file: $POM_FILE"
echo "AWS Region: $AWS_REGION"
echo "CodeArtifact Domain: $DOMAIN_NAME"
echo "CodeArtifact Repo: $REPO_NAME"
echo ""

# Create work directory
mkdir -p "$WORK_DIR"

# Initialize not-found file
echo "# Packages not found in Chainguard libraries" > "$NOT_FOUND_FILE"
echo "# These will be pulled from Maven Central via CodeArtifact fallback" >> "$NOT_FOUND_FILE"
echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$NOT_FOUND_FILE"
echo "" >> "$NOT_FOUND_FILE"

# Get CodeArtifact auth token and endpoint
echo "Obtaining CodeArtifact credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

CODEARTIFACT_AUTH_TOKEN=$(aws codeartifact get-authorization-token \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" \
    --query 'authorizationToken' \
    --output text)

CODEARTIFACT_ENDPOINT=$(aws codeartifact get-repository-endpoint \
    --domain "$DOMAIN_NAME" \
    --repository "$REPO_NAME" \
    --format maven \
    --region "$AWS_REGION" \
    --query 'repositoryEndpoint' \
    --output text)

echo "CodeArtifact endpoint: $CODEARTIFACT_ENDPOINT"
echo ""

# Parse pom.xml and extract dependencies
# Uses grep/sed for portability (no xmllint dependency)
parse_pom_dependencies() {
    local in_dependencies=false
    local in_dependency=false
    local group_id=""
    local artifact_id=""
    local version=""

    while IFS= read -r line; do
        # Check for dependencies section
        if [[ "$line" =~ \<dependencies\> ]]; then
            in_dependencies=true
            continue
        fi
        if [[ "$line" =~ \</dependencies\> ]]; then
            in_dependencies=false
            continue
        fi

        if [[ "$in_dependencies" == true ]]; then
            # Check for dependency element
            if [[ "$line" =~ \<dependency\> ]]; then
                in_dependency=true
                group_id=""
                artifact_id=""
                version=""
                continue
            fi
            if [[ "$line" =~ \</dependency\> ]]; then
                in_dependency=false
                # Output if we have all three values
                if [[ -n "$group_id" && -n "$artifact_id" && -n "$version" ]]; then
                    # Skip variable versions like ${project.version}
                    if [[ ! "$version" =~ ^\$ ]]; then
                        echo "$group_id:$artifact_id:$version"
                    fi
                fi
                continue
            fi

            if [[ "$in_dependency" == true ]]; then
                # Extract groupId
                if [[ "$line" =~ \<groupId\>([^<]+)\</groupId\> ]]; then
                    group_id="${BASH_REMATCH[1]}"
                fi
                # Extract artifactId
                if [[ "$line" =~ \<artifactId\>([^<]+)\</artifactId\> ]]; then
                    artifact_id="${BASH_REMATCH[1]}"
                fi
                # Extract version
                if [[ "$line" =~ \<version\>([^<]+)\</version\> ]]; then
                    version="${BASH_REMATCH[1]}"
                fi
            fi
        fi
    done < "$POM_FILE"
}

# Check if artifact exists in Chainguard Maven repo
check_chainguard_maven() {
    local group_id="$1"
    local artifact_id="$2"
    local version="$3"

    # Convert groupId to path (com.example -> com/example)
    local group_path="${group_id//./\/}"

    # Construct URL to the artifact
    local artifact_url="${CGR_MAVEN_INDEX}${group_path}/${artifact_id}/${version}/${artifact_id}-${version}.jar"

    # Check if artifact exists (use netrc for auth)
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --netrc "$artifact_url" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

# Download artifact from Chainguard
download_from_chainguard() {
    local group_id="$1"
    local artifact_id="$2"
    local version="$3"

    # Clean work directory
    rm -f "$WORK_DIR"/*.jar "$WORK_DIR"/*.pom

    local group_path="${group_id//./\/}"
    local base_url="${CGR_MAVEN_INDEX}${group_path}/${artifact_id}/${version}"

    # Download JAR
    local jar_url="${base_url}/${artifact_id}-${version}.jar"
    local jar_file="$WORK_DIR/${artifact_id}-${version}.jar"

    if ! curl -s --netrc -o "$jar_file" "$jar_url"; then
        return 1
    fi

    if [[ ! -s "$jar_file" ]]; then
        rm -f "$jar_file"
        return 1
    fi

    # Try to download POM (optional, may not exist)
    local pom_url="${base_url}/${artifact_id}-${version}.pom"
    local pom_file="$WORK_DIR/${artifact_id}-${version}.pom"
    curl -s --netrc -o "$pom_file" "$pom_url" 2>/dev/null || true

    return 0
}

# Upload artifact to CodeArtifact using mvn deploy:deploy-file
upload_to_codeartifact() {
    local group_id="$1"
    local artifact_id="$2"
    local version="$3"

    local jar_file="$WORK_DIR/${artifact_id}-${version}.jar"
    local pom_file="$WORK_DIR/${artifact_id}-${version}.pom"

    if [[ ! -f "$jar_file" ]]; then
        echo "    Warning: JAR file not found"
        return 1
    fi

    # Set package origin controls to allow direct publish and block upstream
    echo "    Configuring package origin controls..."
    aws codeartifact put-package-origin-configuration \
        --domain "$DOMAIN_NAME" \
        --repository "$REPO_NAME" \
        --format maven \
        --namespace "$group_id" \
        --package "$artifact_id" \
        --restrictions "publish=ALLOW,upstream=BLOCK" \
        --region "$AWS_REGION" \
        > /dev/null 2>&1 || true

    echo "    Uploading to CodeArtifact..."

    # Build mvn deploy command
    local mvn_args=(
        "deploy:deploy-file"
        "-DgroupId=$group_id"
        "-DartifactId=$artifact_id"
        "-Dversion=$version"
        "-Dpackaging=jar"
        "-Dfile=$jar_file"
        "-DrepositoryId=codeartifact"
        "-Durl=$CODEARTIFACT_ENDPOINT"
    )

    # Add POM if available
    if [[ -f "$pom_file" && -s "$pom_file" ]]; then
        mvn_args+=("-DpomFile=$pom_file")
    else
        mvn_args+=("-DgeneratePom=true")
    fi

    # Create temporary settings.xml for auth
    local settings_file
    settings_file=$(mktemp)
    cat > "$settings_file" <<EOF
<settings>
  <servers>
    <server>
      <id>codeartifact</id>
      <username>aws</username>
      <password>$CODEARTIFACT_AUTH_TOKEN</password>
    </server>
  </servers>
</settings>
EOF

    local upload_output
    upload_output=$(mktemp)

    if mvn -s "$settings_file" -B "${mvn_args[@]}" > "$upload_output" 2>&1; then
        rm -f "$settings_file" "$upload_output"
        return 0
    else
        if grep -qi "already exists\|Conflict\|409" "$upload_output"; then
            echo "    Package version already exists in CodeArtifact (OK)"
            rm -f "$settings_file" "$upload_output"
            return 0
        else
            echo "    Warning: Upload failed"
            grep -i "error\|failed" "$upload_output" | head -5 || true
            rm -f "$settings_file" "$upload_output"
            return 1
        fi
    fi
}

# Parse dependencies from pom.xml
echo "Parsing POM file..."
DEPENDENCIES=$(parse_pom_dependencies)

if [[ -z "$DEPENDENCIES" ]]; then
    echo "No dependencies with explicit versions found in POM file."
    echo "Note: Dependencies using variable versions (e.g., \${project.version}) are skipped."
    exit 0
fi

TOTAL_DEPS=$(echo "$DEPENDENCIES" | wc -l | tr -d ' ')
echo "Found $TOTAL_DEPS dependencies to process"
echo ""

# Counters
FOUND_COUNT=0
NOT_FOUND_COUNT=0
FAILED_UPLOAD_COUNT=0

# Process each dependency
echo "Processing dependencies..."
echo ""

while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue

    # Parse groupId:artifactId:version
    IFS=':' read -r group_id artifact_id version <<< "$dep"

    echo "----------------------------------------"
    echo "Processing: $group_id:$artifact_id:$version"

    # Check Chainguard
    echo "  Checking Chainguard Java index..."
    if check_chainguard_maven "$group_id" "$artifact_id" "$version"; then
        echo "  Found in Chainguard!"
        FOUND_COUNT=$((FOUND_COUNT + 1))

        if download_from_chainguard "$group_id" "$artifact_id" "$version"; then
            if upload_to_codeartifact "$group_id" "$artifact_id" "$version"; then
                echo "  Successfully synced!"
            else
                FAILED_UPLOAD_COUNT=$((FAILED_UPLOAD_COUNT + 1))
            fi
        else
            echo "  Warning: Download failed"
            FAILED_UPLOAD_COUNT=$((FAILED_UPLOAD_COUNT + 1))
        fi
    else
        echo "  Not found in Chainguard - will use Maven Central fallback"
        NOT_FOUND_COUNT=$((NOT_FOUND_COUNT + 1))
        echo "$group_id:$artifact_id:$version" >> "$NOT_FOUND_FILE"
    fi

done <<< "$DEPENDENCIES"

# Clean up
rm -rf "$WORK_DIR"

echo ""
echo "=========================================="
echo "Sync Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Total dependencies:              $TOTAL_DEPS"
echo "  Found in Chainguard:             $FOUND_COUNT"
echo "  Not found (Maven Central fallback): $NOT_FOUND_COUNT"
echo "  Failed to upload:                $FAILED_UPLOAD_COUNT"
echo ""
echo "Packages not found in Chainguard are recorded in: $NOT_FOUND_FILE"
echo "These packages will be pulled from Maven Central via the CodeArtifact fallback."
