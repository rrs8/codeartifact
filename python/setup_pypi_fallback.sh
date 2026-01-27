#!/usr/bin/env bash
set -euo pipefail

# Recommended two-repo pattern:
# - Create/ensure a dedicated PUBLIC_REPO with external connection to PyPI
# - Add PUBLIC_REPO as an upstream of your primary REPO
#
# This allows fallback to PyPI (pull-on-miss + cache) without putting the
# “no publish if version exists in PyPI” constraint on your primary repo.  :llmCitationRef[2] :llmCitationRef[3]

# ====== Configure these ======
export AWS_REGION=us-east-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DOMAIN="cg-demo-domain"
export REPO="cg-demo-pypi"
export OWNER="rich.schofield"
export PROJECT="cg-libs-demo-gp"
export SOURCE="https://github.com/chainguard-dev/ynad"
export PUBLIC_REPO=${PUBLIC_REPO:-pypi-public}  # shared cache for PyPI

# ====== Helpers ======
note() { printf "\n==> %s\n" "$*"; }
err()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }

aws_ca() {
  aws --region "$AWS_REGION" --domain-owner "$ACCOUNT_ID" "$@"
}

# ====== Ensure domain exists ======
note "Checking/creating domain: $DOMAIN"
if ! aws_ca codeartifact describe-domain --domain "$DOMAIN" --query domain.name --output text >/dev/null 2>&1; then
  note "Domain not found. Creating domain: $DOMAIN"
  aws_ca codeartifact create-domain --domain "$DOMAIN" >/dev/null
fi

# ====== Ensure PUBLIC_REPO exists ======
note "Checking/creating public cache repo: $PUBLIC_REPO"
if ! aws_ca codeartifact describe-repository \
    --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" --repository "$PUBLIC_REPO" \
    --query repository.name --output text >/dev/null 2>&1; then
  aws_ca codeartifact create-repository \
    --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
    --repository "$PUBLIC_REPO" \
    --description "Shared cache for public PyPI" >/dev/null
  note "Created $PUBLIC_REPO"
else
  note "$PUBLIC_REPO already exists"
fi

# ====== Attach external connection to PyPI on PUBLIC_REPO ======
note "Ensuring external connection to PyPI on $PUBLIC_REPO"
EXTERNALS=$(aws_ca codeartifact describe-repository \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" --repository "$PUBLIC_REPO" \
  --query "repository.externalConnections[].externalConnectionName" --output text || true)

if grep -q "public:pypi" <<< "$EXTERNALS"; then
  note "External connection public:pypi already present on $PUBLIC_REPO"
else
  aws_ca codeartifact associate-external-connection \
    --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
    --repository "$PUBLIC_REPO" \
    --external-connection public:pypi >/dev/null
  note "Added external connection public:pypi to $PUBLIC_REPO"
fi

# ====== Ensure your primary REPO exists ======
note "Checking primary repo: $REPO"
aws_ca codeartifact describe-repository \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" --repository "$REPO" \
  --query repository.name --output text >/dev/null \
  || err "Primary repo $REPO not found in domain $DOMAIN. Create it first."

# ====== Add PUBLIC_REPO as an upstream to REPO (preserving existing upstreams) ======
note "Adding $PUBLIC_REPO as upstream to $REPO (if not present)"
CURRENT_UPS=$(aws_ca codeartifact describe-repository \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" --repository "$REPO" \
  --query "repository.upstreams[].repositoryName" --output text || true)

# Build new upstream list (avoid duplicates)
NEW_UPS=()
FOUND=0
for u in $CURRENT_UPS; do
  if [[ "$u" == "$PUBLIC_REPO" ]]; then FOUND=1; fi
  NEW_UPS+=("repositoryName=$u")
done
if [[ $FOUND -eq 0 ]]; then
  NEW_UPS+=("repositoryName=$PUBLIC_REPO")
fi

# Only update if needed
if [[ $FOUND -eq 1 ]]; then
  note "$PUBLIC_REPO is already an upstream of $REPO"
else
  note "Updating upstreams on $REPO -> ${NEW_UPS[*]}"
  aws_ca codeartifact update-repository \
    --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
    --repository "$REPO" \
    --upstreams "${NEW_UPS[@]}" >/dev/null
  note "Upstreams updated"
fi

# ====== Optional: show endpoints and quick pip login hint ======
PRIMARY_ENDPOINT=$(aws_ca codeartifact get-repository-endpoint \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
  --repository "$REPO" --format pypi \
  --query repositoryEndpoint --output text)

note "Primary install endpoint for pip (must end with /simple/):"
echo "  ${PRIMARY_ENDPOINT}simple/"  # pip install endpoint  :llmCitationRef[4]

note "To configure pip for installs (writes pip.conf):"
echo "  aws codeartifact login --tool pip --region $AWS_REGION --domain $DOMAIN --domain-owner $ACCOUNT_ID --repository $REPO"

note "Done. Your $REPO now falls back to PyPI via $PUBLIC_REPO and caches results."
note "New versions published to PyPI can take up to ~30 minutes to appear via CodeArtifact due to regional metadata caches."  #  :llmCitationRef[5]
