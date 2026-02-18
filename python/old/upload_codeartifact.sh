#!/bin/bash
# Set these to your dev account context (after SSO)
export AWS_REGION=us-east-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

export DOMAIN="cg-demo-domain"
export REPO="cg-demo-pypi"

# Get 12-hour auth token and endpoint
export TWINE_USERNAME=aws
export TWINE_PASSWORD=$(aws codeartifact get-authorization-token \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
  --query authorizationToken --output text)
export TWINE_REPOSITORY_URL=$(aws codeartifact get-repository-endpoint \
  --domain "$DOMAIN" --domain-owner "$ACCOUNT_ID" \
  --repository "$REPO" --format pypi \
  --query repositoryEndpoint --output text)

# Upload the downloaded wheels/sdists
twine upload --repository-url "$TWINE_REPOSITORY_URL" stage/*
