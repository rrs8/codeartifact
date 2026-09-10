#!/bin/bash
# Tag AWS CodeArtifact domains and repositories after the fact.
#
# Useful when:
#   - Your org requires tags on all AWS resources (project, owner, source)
#   - You need anti-cleanup tags (e.g. aws-nuke-ignore=true) in accounts with
#     aggressive auto-teardown
#   - You need to tag resources created before the setup scripts supported
#     CODEARTIFACT_TAGS
#
# Usage:
#   ./tag-codeartifact.sh --domain D [--repository R] --tag k=v [--tag k=v ...]
#
# Required:
#   --domain DOMAIN        Domain to tag (and optionally any of its repositories)
#   --tag KEY=VALUE        A tag to apply (repeatable). At least one required.
#
# Optional:
#   --repository REPO      Repository within the domain to also tag (repeatable)
#   --all-repos            Tag every repository in the domain
#   --region REGION        AWS region (default: us-east-2 or $AWS_REGION)
#   -h, --help
#
# Examples:
#   # Tag just the domain
#   ./tag-codeartifact.sh --domain my-pypi-domain \
#       --tag project=my-poc --tag owner=me@example.com
#
#   # Tag domain + specific repos
#   ./tag-codeartifact.sh --domain my-pypi-domain \
#       --repository my-pypi-repo --repository pypi-public \
#       --tag project=my-poc --tag aws-nuke-ignore=true
#
#   # Tag domain + every repo in it
#   ./tag-codeartifact.sh --domain my-pypi-domain --all-repos \
#       --tag project=my-poc --tag owner=me@example.com \
#       --tag source=https://github.com/me/infra

set -euo pipefail

DOMAIN=""
REPOS=()
ALL_REPOS=false
TAGS=()
REGION="${AWS_REGION:-us-east-2}"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^set -euo pipefail'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --repository)  REPOS+=("$2"); shift 2 ;;
        --all-repos)   ALL_REPOS=true; shift ;;
        --tag)         TAGS+=("key=${2%%=*},value=${2#*=}"); shift 2 ;;
        --region)      REGION="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$DOMAIN"      ]] && { echo "ERROR: --domain required" >&2; usage 1; }
[[ ${#TAGS[@]} -eq 0 ]] && { echo "ERROR: at least one --tag required" >&2; usage 1; }

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

if [[ "$ALL_REPOS" == "true" ]]; then
    # Read loop rather than `mapfile`: mapfile is bash 4+, and the shebang
    # resolves to bash 3.2 on stock macOS.
    REPOS=()
    while IFS= read -r repo; do
        [[ -n "$repo" ]] && REPOS+=("$repo")
    done < <(aws codeartifact list-repositories-in-domain \
        --domain "$DOMAIN" --region "$REGION" \
        --query 'repositories[].name' --output text | tr '\t' '\n')
fi

echo "=========================================="
echo "Tag CodeArtifact resources"
echo "=========================================="
echo "Account:  $ACCOUNT"
echo "Region:   $REGION"
echo "Domain:   $DOMAIN"
if [[ ${#REPOS[@]} -gt 0 ]]; then
    echo "Repos:    ${REPOS[*]}"
fi
echo "Tags:"
for t in "${TAGS[@]}"; do echo "  $t"; done
echo

apply_tags() {
    local arn="$1" kind="$2"
    echo "Tagging $kind: $arn"
    if aws codeartifact tag-resource \
        --region "$REGION" \
        --resource-arn "$arn" \
        --tags "${TAGS[@]}" > /dev/null; then
        echo "  OK"
    else
        echo "  WARN: tag-resource failed"
    fi
}

apply_tags \
    "arn:aws:codeartifact:${REGION}:${ACCOUNT}:domain/${DOMAIN}" \
    "domain"

for repo in "${REPOS[@]}"; do
    apply_tags \
        "arn:aws:codeartifact:${REGION}:${ACCOUNT}:repository/${DOMAIN}/${repo}" \
        "repository"
done

echo
echo "Verify:"
echo "  aws codeartifact list-tags-for-resource --region $REGION \\"
echo "      --resource-arn arn:aws:codeartifact:${REGION}:${ACCOUNT}:domain/${DOMAIN}"
