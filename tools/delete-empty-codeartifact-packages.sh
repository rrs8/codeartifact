#!/bin/bash
# Delete packages from a CodeArtifact repository that have 0 published versions.
#
# Use case: a sync run left behind "ghost" package entries (origin config set
# but publish failed, e.g. 409 upstream-claim conflicts). These ghosts have no
# content but block subsequent re-sync attempts until removed.
#
# Usage:
#   ./delete-empty-codeartifact-packages.sh --domain D --repository R [options]
#
# Required:
#   --domain DOMAIN
#   --repository REPO
#
# Optional:
#   --region REGION     AWS region (default: us-east-2 or $AWS_REGION)
#   --format FORMAT     Only delete packages of this format: pypi|npm|maven|...
#                       (default: check all formats in the repo)
#   --filter REGEX      Only packages whose name matches this regex
#   --dry-run           Show what would be deleted; don't actually delete
#   -h, --help

set -euo pipefail

DOMAIN=""
REPO=""
REGION="${AWS_REGION:-us-east-2}"
FORMAT=""
FILTER=""
DRY_RUN=false

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^set -euo pipefail'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)     DOMAIN="$2"; shift 2 ;;
        --repository|--repo) REPO="$2"; shift 2 ;;
        --region)     REGION="$2"; shift 2 ;;
        --format)     FORMAT="$2"; shift 2 ;;
        --filter)     FILTER="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$DOMAIN" ]] && { echo "ERROR: --domain is required" >&2; usage 1; }
[[ -z "$REPO"   ]] && { echo "ERROR: --repository is required" >&2; usage 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found"     >&2; exit 1; }

format_supports_namespace() {
    case "$1" in
        npm|maven|generic|swift) return 0 ;;
        *) return 1 ;;
    esac
}

echo "=========================================="
echo "Delete empty CodeArtifact packages"
echo "=========================================="
echo "Domain:     $DOMAIN"
echo "Repository: $REPO"
echo "Region:     $REGION"
echo "Format:     ${FORMAT:-(all)}"
echo "Filter:     ${FILTER:-(none)}"
echo "Mode:       $($DRY_RUN && echo 'DRY-RUN' || echo 'APPLY')"
echo

list_args=(--domain "$DOMAIN" --repository "$REPO" --region "$REGION" --output json)
[[ -n "$FORMAT" ]] && list_args+=(--format "$FORMAT")

echo "Listing packages..."
raw=$(aws codeartifact list-packages "${list_args[@]}")
total=$(echo "$raw" | jq '.packages | length')
echo "Found $total packages in repository"
echo

# Pipe-delimited: format|namespace|package  (use | because tab is IFS whitespace)
pkgs=$(echo "$raw" | jq -r '.packages[] | [.format, (.namespace // ""), .package] | join("|")')

empty=0
nonempty=0
deleted=0
failed=0
skipped=0

while IFS='|' read -r fmt ns pkg; do
    [[ -z "${fmt:-}" ]] && continue

    display="$pkg"
    [[ -n "$ns" ]] && format_supports_namespace "$fmt" && display="@${ns}/${pkg}"

    if [[ -n "$FILTER" ]] && ! echo "$display" | grep -qE "$FILTER"; then
        skipped=$((skipped + 1))
        continue
    fi

    lpv_args=(--domain "$DOMAIN" --repository "$REPO" --region "$REGION" --format "$fmt" --package "$pkg")
    if [[ -n "$ns" ]] && format_supports_namespace "$fmt"; then
        lpv_args+=(--namespace "$ns")
    fi

    ver_count=$(aws codeartifact list-package-versions "${lpv_args[@]}" --output json 2>/dev/null | jq '.versions | length')

    if [[ "$ver_count" -gt 0 ]]; then
        nonempty=$((nonempty + 1))
        continue
    fi

    empty=$((empty + 1))
    printf "  [%s] %s: 0 versions -> %s\n" "$fmt" "$display" "$($DRY_RUN && echo 'WOULD DELETE' || echo 'deleting')"

    [[ "$DRY_RUN" == "true" ]] && continue

    del_args=(aws codeartifact delete-package \
        --domain "$DOMAIN" \
        --repository "$REPO" \
        --region "$REGION" \
        --format "$fmt" \
        --package "$pkg")
    if [[ -n "$ns" ]] && format_supports_namespace "$fmt"; then
        del_args+=(--namespace "$ns")
    fi

    err_file=$(mktemp)
    if "${del_args[@]}" > /dev/null 2> "$err_file"; then
        deleted=$((deleted + 1))
    else
        failed=$((failed + 1))
        echo "    WARN: delete failed: $(cat "$err_file")"
    fi
    rm -f "$err_file"
done <<< "$pkgs"

echo
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "  Total in repo:              $total"
echo "  Filtered out:               $skipped"
echo "  Had versions (kept):        $nonempty"
echo "  Empty (0 versions):         $empty"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would delete:               $empty"
    echo
    echo "Dry-run complete. Re-run without --dry-run to apply."
else
    echo "  Deleted:                    $deleted"
    echo "  Failed to delete:           $failed"
fi
