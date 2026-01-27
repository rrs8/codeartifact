#!/bin/bash
#!/usr/bin/env bash
set -euo pipefail

# Sync all available versions of a Python package from the current pip index
# into a local stage/ directory, then publish them to AWS CodeArtifact via Twine.
#
# Requirements:
# - pip and twine installed
# - AWS CLI authenticated (SSO or keys) with permissions to CodeArtifact
# - Your pip is already pointing at the source index (e.g., CGR) OR pass INDEX_URL
#
# Usage:
#   PACKAGE=flask DOMAIN=cg-demo-domain REPO=cg-demo-pypi ./sync_all_versions_to_codeartifact.sh
#
# Optional env:
#   INDEX_URL          Override the source index (e.g., https://user:token@libraries.cgr.dev/python/simple/)
#   AWS_REGION         Defaults to current AWS CLI region/profile setting
#   ACCOUNT_ID         Auto-detected via STS if not provided
#   SKIP_DOWNLOAD=1    Skip downloading if file exists in stage/ already
#   TWINE_SKIP_EXISTING=1  Pass --skip-existing to twine (ignore 409s on already-published)

export PACKAGE="werkzeug"
export DOMAIN="cg-demo-domain"
export REPO="cg-demo-pypi"

export AWS_REGION="us-east-2"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Package     : ${PACKAGE}"
echo "Domain      : ${DOMAIN}"
echo "Repository  : ${REPO}"
echo "Account     : ${ACCOUNT_ID}"

# 1) Discover all versions visible on the configured index (or INDEX_URL if provided)
# Extract versions from: `pip index versions PACKAGE`
# Extract the versions line
VERSIONS_LINE="$(pip index versions "${PACKAGE}" 2>/dev/null | awk -F': ' '/Available versions:/ {print $2}')"
if [[ -z "${VERSIONS_LINE}" ]]; then
  echo "Could not read versions for ${PACKAGE} from pip. Check your pip index configuration (or set INDEX_URL)." >&2
  exit 1
fi

# Build array without mapfile (macOS bash-compatible)
IFS=',' read -r -a VERS_RAW <<< "${VERSIONS_LINE}"
VERSIONS=()
for v in "${VERS_RAW[@]}"; do
  v="${v//[[:space:]]/}"   # trim all whitespace
  [[ -n "$v" ]] && VERSIONS+=("$v")
done

echo "Found ${#VERSIONS[@]} versions:"
printf ' - %s\n' "${VERSIONS[@]}"

# 2) Download artifacts for each version into stage/
mkdir -p stage
download_one() {
  local v="$1"
  local spec="${PACKAGE}==${v}"
  echo "Downloading ${spec} …"
  # Try wheel-only first; if not available, fall back to sdist
  if ! pip download "${spec}" --no-deps --only-binary=:all: -d stage ; then
    echo "Wheel not found for ${spec}, NOT trying sdist …"
    # pip download "${spec}" --no-deps --no-binary=:all: -d stage 
  fi
}
for v in "${VERSIONS[@]}"; do
  if [[ "${SKIP_DOWNLOAD:-0}" == "1" ]] && compgen -G "stage/${PACKAGE}-${v}-*" > /dev/null; then
    echo "Skipping ${PACKAGE}==${v} (already present in stage/)"
    continue
  fi
  download_one "${v}"
done

# 3) Authenticate Twine to CodeArtifact (12h auth token)
export TWINE_USERNAME=aws
export TWINE_PASSWORD="$(aws codeartifact get-authorization-token \
  --domain "${DOMAIN}" --domain-owner "${ACCOUNT_ID}" \
  --query authorizationToken --output text)"
export TWINE_REPOSITORY_URL="$(aws codeartifact get-repository-endpoint \
  --domain "${DOMAIN}" --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" --format pypi \
  --query repositoryEndpoint --output text)"

# 4) Publish everything in stage/ to CodeArtifact
# Build args safely so we never expand an empty array under `set -u`
TWINE_ARGS=(--repository-url "${TWINE_REPOSITORY_URL}")
if [[ "${TWINE_SKIP_EXISTING:-0}" == "1" ]]; then
  TWINE_ARGS=(--skip-existing "${TWINE_ARGS[@]}")
fi

echo "Uploading artifacts from ./stage to CodeArtifact repository ${REPO} in domain ${DOMAIN} …"
twine upload "${TWINE_ARGS[@]}" stage/*
echo "Done."
