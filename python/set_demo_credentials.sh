#!/bin/bash
ENDPOINT=$(aws codeartifact get-repository-endpoint \
  --domain cg-demo-domain \
  --domain-owner 452336408843 \
  --repository cg-demo-pypi \
  --format pypi \
  --query repositoryEndpoint --output text)

pip config set global.index-url "${ENDPOINT}simple/"
# pip config set global.extra-index-url https://pypi.org/simple  # optional

HOST="cg-demo-domain-452336408843.d.codeartifact.us-east-2.amazonaws.com"
TOKEN=$(aws codeartifact get-authorization-token --domain cg-demo-domain --domain-owner 452336408843 --query authorizationToken --output text)
awk -v host="$HOST" -v tok="$TOKEN" '
BEGIN{printed=0}
$1=="machine" && $2==host {print; getline; print "  login aws"; getline; print "  password " tok; printed=1; next}
{print}
END{if(!printed){print "machine " host "\n  login aws\n  password " tok}}
' ~/.netrc > ~/.netrc.new && mv ~/.netrc.new ~/.netrc && chmod 600 ~/.netrc
