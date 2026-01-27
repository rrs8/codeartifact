@!/bin/bash
# Set these to your dev account context (after SSO)
export AWS_REGION=us-east-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

export DOMAIN="cg-demo-domain"
export REPO="cg-demo-pypi"
export OWNER="rich.schofield"
export PROJECT="cg-libs-demo-gp"
export SOURCE="https://github.com/chainguard-dev/ynad"

# Create once (safe to re-run; it will error if already exists)
aws codeartifact create-domain --domain "$DOMAIN" \
  --tags key=project,value="$PROJECT" \
         key=owner,value="$OWNER" \
         key=source,value="$SOURCE" || true
aws codeartifact create-repository \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
  --repository "$REPO" --description "Temp demo repo - schofr" \
  --tags key=project,value="$PROJECT" \
         key=owner,value="$OWNER" \
         key=source,value="$SOURCE" || true