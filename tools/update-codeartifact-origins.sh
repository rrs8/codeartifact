#!/bin/bash
# Update origin controls (publish/upstream) for all packages in a CodeArtifact
# repository. Useful when you need to flip a policy in bulk — e.g. moving from
# strict "no upstream fallback" to permissive "CG-preferred, upstream fallback".
#
# Usage:
#   ./update-codeartifact-origins.sh --domain D --repository R [options]
#
# Required:
#   --domain DOMAIN
#   --repository REPO
#
# Optional:
#   --region REGION          AWS region (default: us-east-2 or $AWS_REGION)
#   --format FORMAT          Only touch packages of this format: pypi|npm|maven|nuget|generic|swift|ruby|cargo
#                            (default: update every package in the repo regardless of format)
#   --publish VALUE          ALLOW | BLOCK (default: ALLOW)
#   --upstream VALUE         ALLOW | BLOCK (default: ALLOW)
#   --filter REGEX           Only packages whose name (or @ns/name) matches this regex
#   --dry-run                Show what would change; don't apply
#   -h, --help               Show this help
#
# Examples:
#   # Flip all packages in the Python repo to permit upstream fallback
#   ./update-codeartifact-origins.sh --domain my-pypi-domain --repository my-pypi-repo
#
#   # Strict lockdown on the npm repo (CG-or-bust)
#   ./update-codeartifact-origins.sh --domain my-npm-domain --repository my-npm-repo \
#       --publish ALLOW --upstream BLOCK
#
#   # Preview changes without applying
#   ./update-codeartifact-origins.sh --domain my-pypi-domain --repository my-pypi-repo --dry-run
#
#   # Only update packages matching a regex (useful for scoped namespaces)
#   ./update-codeartifact-origins.sh --domain my-npm-domain --repository my-npm-repo \
#       --filter '^@aws-sdk/'

set -euo pipefail

DOMAIN=""
REPO=""
REGION="${AWS_REGION:-us-east-2}"
FORMAT=""
PUBLISH="ALLOW"
UPSTREAM="ALLOW"
DRY_RUN=false
FILTER=""

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^set -euo pipefail'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)          DOMAIN="$2"; shift 2 ;;
        --repository|--repo) REPO="$2"; shift 2 ;;
        --region)          REGION="$2"; shift 2 ;;
        --format)          FORMAT="$2"; shift 2 ;;
        --publish)         PUBLISH="$2"; shift 2 ;;
        --upstream)        UPSTREAM="$2"; shift 2 ;;
        --filter)          FILTER="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        -h|--help)         usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$DOMAIN" ]] && { echo "ERROR: --domain is required" >&2; usage 1; }
[[ -z "$REPO"   ]] && { echo "ERROR: --repository is required" >&2; usage 1; }

for v in "$PUBLISH" "$UPSTREAM"; do
    if [[ "$v" != "ALLOW" && "$v" != "BLOCK" ]]; then
        echo "ERROR: --publish/--upstream must be ALLOW or BLOCK (got: $v)" >&2
        exit 1
    fi
done

for cmd in aws jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

echo "=========================================="
echo "Update CodeArtifact origin controls"
echo "=========================================="
echo "Domain:     $DOMAIN"
echo "Repository: $REPO"
echo "Region:     $REGION"
echo "Format:     ${FORMAT:-(all)}"
echo "Filter:     ${FILTER:-(none)}"
echo "Target:     publish=$PUBLISH,upstream=$UPSTREAM"
echo "Mode:       $($DRY_RUN && echo 'DRY-RUN (no changes)' || echo 'APPLY')"
echo

# List all packages in the repo. AWS CLI auto-paginates across result pages.
list_args=(--domain "$DOMAIN" --repository "$REPO" --region "$REGION" --output json)
[[ -n "$FORMAT" ]] && list_args+=(--format "$FORMAT")

echo "Listing packages..."
raw_json=$(aws codeartifact list-packages "${list_args[@]}")
total=$(echo "$raw_json" | jq '.packages | length')
echo "Found $total packages in repository"
echo

# Emit pipe-delimited: format|namespace|package|current_publish|current_upstream
# (namespace is empty string for non-scoped / non-namespaced formats)
#
# NOTE: using '|' instead of tab because bash's `IFS=$'\t' read` collapses
# consecutive tabs (tab is "IFS whitespace"), which misaligns fields when the
# namespace is empty. '|' is NOT IFS whitespace, so empty fields are preserved.
package_list=$(echo "$raw_json" | jq -r '
    .packages[] |
    [
      .format,
      (.namespace // ""),
      .package,
      (.originConfiguration.restrictions.publish // "UNSET"),
      (.originConfiguration.restrictions.upstream // "UNSET")
    ] | join("|")
')

# Formats that support a namespace in put-package-origin-configuration.
# pypi, nuget, ruby, cargo do NOT accept --namespace.
format_supports_namespace() {
    case "$1" in
        npm|maven|generic|swift) return 0 ;;
        *) return 1 ;;
    esac
}

ok=0
skipped=0
failed=0
matched=0

while IFS='|' read -r fmt ns pkg cur_pub cur_up; do
    [[ -z "${fmt:-}" ]] && continue

    display_name="$pkg"
    if [[ -n "$ns" ]] && format_supports_namespace "$fmt"; then
        display_name="@${ns}/${pkg}"
    fi

    # Apply filter if provided
    if [[ -n "$FILTER" ]] && ! echo "$display_name" | grep -qE "$FILTER"; then
        continue
    fi
    matched=$((matched + 1))

    # Skip if already at target state
    if [[ "$cur_pub" == "$PUBLISH" && "$cur_up" == "$UPSTREAM" ]]; then
        printf "  SKIP  [%s] %s: already at publish=%s,upstream=%s\n" "$fmt" "$display_name" "$PUBLISH" "$UPSTREAM"
        skipped=$((skipped + 1))
        continue
    fi

    printf "  CHANGE[%s] %s: publish=%s,upstream=%s -> publish=%s,upstream=%s\n" \
        "$fmt" "$display_name" "$cur_pub" "$cur_up" "$PUBLISH" "$UPSTREAM"

    if [[ "$DRY_RUN" == "true" ]]; then
        continue
    fi

    put_args=(aws codeartifact put-package-origin-configuration \
        --domain "$DOMAIN" \
        --repository "$REPO" \
        --region "$REGION" \
        --format "$fmt" \
        --package "$pkg" \
        --restrictions "publish=$PUBLISH,upstream=$UPSTREAM")
    if [[ -n "$ns" ]] && format_supports_namespace "$fmt"; then
        put_args+=(--namespace "$ns")
    fi

    err_file=$(mktemp)
    if "${put_args[@]}" > /dev/null 2> "$err_file"; then
        ok=$((ok + 1))
    else
        failed=$((failed + 1))
        echo "    WARN: update failed: $(cat "$err_file")"
    fi
    rm -f "$err_file"
done <<< "$package_list"

echo
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "  Total packages in repo:  $total"
echo "  Matched filter:          $matched"
echo "  Already at target:       $skipped"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would change:            $((matched - skipped))"
    echo
    echo "This was a dry run. Re-run without --dry-run to apply."
else
    echo "  Updated successfully:    $ok"
    echo "  Failed:                  $failed"
fi
