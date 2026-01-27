#!/usr/bin/env bash
set -euo pipefail

# Install a specific Flask version from AWS CodeArtifact into a fresh venv.
#
# Usage:
#   VERSION=2.1.3 ./scripts/install_from_codeartifact.sh
#   VERSION=2.1.3+cgr.1 ./scripts/install_from_codeartifact.sh
#
# Required env:
#   DOMAIN=cg-demo-domain
#   ACCOUNT_ID=452336408843
#   REPO=cg-demo-pypi
#   AWS_REGION=us-east-2
#
# Optional:
#   USE_PIP_CONF=1  # If set, rely on pre-configured pip.conf index-url
#   PYTHON=python3  # Python executable
#
# Notes:
# - If USE_PIP_CONF is not set, we compute a tokenized /simple endpoint and use -i.
# - Token defaults to ~12h; re-run if it times out.

: "${VERSION:?Set VERSION, e.g. VERSION=2.1.3 or VERSION=2.1.3+cgr.1}"
: "${DOMAIN:?Set DOMAIN}"
: "${ACCOUNT_ID:?Set ACCOUNT_ID}"
: "${REPO:?Set REPO}"
: "${AWS_REGION:?Set AWS_REGION}"
PYTHON="${PYTHON:-python3}"

# venv setup
rm -rf .venv
"$PYTHON" -m venv .venv
. .venv/bin/activate
pip install --upgrade pip

TOKEN=$(aws --region "$AWS_REGION" codeartifact get-authorization-token \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
  --query authorizationToken --output text)

ENDPOINT=$(aws --region "$AWS_REGION" codeartifact get-repository-endpoint \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
  --repository "$REPO" --format pypi \
  --query repositoryEndpoint --output text)

# pip “install” endpoint must end with /simple/
CA_SIMPLE="https://aws:${TOKEN}@${ENDPOINT#https://}simple/"

FLASK_SPEC="flask==${VERSION}"

# If you’re demoing 2.1.x (or 2.0.x), pin Werkzeug to <3.0
REQS=("$FLASK_SPEC")
REQS+=("werkzeug<3.0") 
REQS+=("jinja2>=3.0")
REQS+=("itsdangerous>=2.0")
REQS+=("click>=8.0")
REQS+=("markupsafe>=2.0")


if [[ "${USE_PIP_CONF:-0}" == "1" ]]; then
  pip install "${REQS[@]}"
else
  pip install -i "$CA_SIMPLE" "${REQS[@]}"
fi

# Add common runtime deps (optional)
#pip install --no-deps "werkzeug" "jinja2" "itsdangerous" "click" "markupsafe"

echo "Flask $(python -c 'import flask; print(flask.__version__)') installed in .venv"
