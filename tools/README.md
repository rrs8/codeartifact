# CodeArtifact Admin Tools

Generic helpers for managing CodeArtifact repositories, complementing the
per-ecosystem `setup-codeartifact.sh` and `sync-chainguard-packages.sh`
scripts.

## Tools

### `update-codeartifact-origins.sh`

Update origin controls (`publish=`, `upstream=`) for all packages in a
repository in bulk. Useful for:

- Switching from strict CG-or-bust (`upstream=BLOCK`) to permissive
  fallback (`upstream=ALLOW`) after a sync
- Retroactively locking down a repo (`upstream=BLOCK`) to block new
  upstream versions
- Dry-run auditing current origin settings before making changes

```bash
# Preview
./update-codeartifact-origins.sh \
    --domain my-pypi-domain --repository my-pypi-repo --dry-run

# Apply: set everything to upstream=ALLOW
./update-codeartifact-origins.sh \
    --domain my-pypi-domain --repository my-pypi-repo

# Lock down a specific namespace
./update-codeartifact-origins.sh \
    --domain my-npm-domain --repository my-npm-repo \
    --publish ALLOW --upstream BLOCK \
    --filter '^@my-org/'
```

Idempotent: already-at-target packages are skipped, not re-pushed.

### `delete-empty-codeartifact-packages.sh`

Delete packages that have 0 versions. Useful for cleaning up "ghost" entries
left by failed sync attempts — when the sync script called
`put-package-origin-configuration` but the subsequent publish failed, CA
keeps the package entry without content.

```bash
# Preview
./delete-empty-codeartifact-packages.sh \
    --domain my-npm-domain --repository my-npm-repo --dry-run

# Apply
./delete-empty-codeartifact-packages.sh \
    --domain my-npm-domain --repository my-npm-repo
```

### `tag-codeartifact.sh`

Apply AWS tags to a domain and its repositories. Useful when:

- Your org requires standard tags on all AWS resources
  (`project`, `owner`, `source`, etc.)
- Your account runs aggressive cleanup jobs (aws-nuke, factory-reset)
  that spare only tagged resources (e.g. `aws-nuke-ignore=true`)
- You need to tag resources created before the `setup-codeartifact.sh`
  scripts supported `CODEARTIFACT_TAGS`

```bash
./tag-codeartifact.sh \
    --domain my-pypi-domain \
    --all-repos \
    --tag project=my-poc \
    --tag owner=me@example.com \
    --tag source=https://github.com/me/infra \
    --tag aws-nuke-ignore=true
```

For new setups, pass tags at creation time via `CODEARTIFACT_TAGS`:

```bash
export CODEARTIFACT_TAGS="key=project,value=my-poc key=owner,value=me@example.com"
./python/setup-codeartifact.sh
```

## Prerequisites

All tools require:

- `aws` CLI configured for the target account
- `jq`
- Permissions for `codeartifact:*` on the target domain/repositories
