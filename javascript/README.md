# JavaScript CodeArtifact + Chainguard Libraries

Scripts to create an AWS CodeArtifact repository for NPM packages and sync Chainguard Libraries packages.

## Prerequisites

- AWS CLI configured with appropriate permissions
- `npm` and `jq` installed
- Chainguard Libraries credentials:
  - `CGR_USERNAME`: Chainguard username
  - `CGR_TOKEN`: Chainguard token

## Scripts

### `setup-codeartifact.sh`

Creates the CodeArtifact domain, upstream repository with NPM public connection, and main repository with fallback.

```bash
./setup-codeartifact.sh
```

### `sync-chainguard-packages-clean.sh`

Reads `package-lock.json` and syncs packages from Chainguard Libraries to CodeArtifact:

1. Extracts all packages from the lockfile
2. Attempts to fetch each package from Chainguard Libraries
3. If found, publishes to CodeArtifact with origin controls set to block upstream (ensuring Chainguard packages take precedence)
4. If not found, records to `chainguard-not-found.txt` (these will fall back to public NPM)

```bash
./sync-chainguard-packages-clean.sh
```

### `cleanup-codeartifact.sh`

Deletes the CodeArtifact repository, upstream repository, and domain.

```bash
./cleanup-codeartifact.sh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-2` | AWS region |
| `CODEARTIFACT_DOMAIN` | `my-npm-domain` | CodeArtifact domain name |
| `CODEARTIFACT_REPO` | `my-npm-repo` | Main repository name |
| `CODEARTIFACT_UPSTREAM_REPO` | `npm-public` | Upstream repository name |
| `LOCKFILE` | `package-lock.json` | Path to lockfile |
| `NOT_FOUND_FILE` | `chainguard-not-found.txt` | Output file for missing packages |
| `CGR_USERNAME` | (required) | Chainguard username |
| `CGR_TOKEN` | (required) | Chainguard token |
| `POST_SYNC_ALLOW_UPSTREAM` | `1` | After sync, flip synced packages from `upstream=BLOCK` to `upstream=ALLOW` so versions CG doesn't build fall through to npm. Set `0` to keep strict "CG-or-bust". |
| `DEBUG` | `false` | Verbose output during npm pack/publish operations |

## Example Usage

```bash
# Set credentials
export CGR_USERNAME=your-username
export CGR_TOKEN=your-token

# Set up CodeArtifact
export CODEARTIFACT_DOMAIN=my-domain
export CODEARTIFACT_REPO=my-repo
./setup-codeartifact.sh

# Sync packages from package-lock.json
./sync-chainguard-packages-clean.sh

# Or with a different lockfile
LOCKFILE=other-package-lock.json ./sync-chainguard-packages-clean.sh

# Clean up when done
./cleanup-codeartifact.sh
```

## How It Works

The sync runs origin controls in **two phases**:

1. **During upload**: sets `publish=ALLOW, upstream=BLOCK` per package.
   This prevents npm's pre-publish metadata GET from triggering CodeArtifact's
   upstream proxy, which would cache the public-npm version and reject our
   Chainguard-built version with a 409 "exists in externally connected
   repository" conflict.
2. **After upload** (automatic, unless `POST_SYNC_ALLOW_UPSTREAM=0`):
   flips synced packages to `upstream=ALLOW` so versions Chainguard didn't
   build fall through to public npm transparently.

### Prerelease versions and provenance

npm's default publish behavior causes two kinds of failures that this script
handles automatically:

- **Prerelease versions** (`*-alpha.N`, `*-beta.N`, `*-rc.N`): npm refuses
  to tag these as `latest`. The script detects prereleases (any version
  containing `-`) and passes `--tag pre` automatically.
- **SLSA provenance**: npm tries to auto-generate provenance attestations,
  which fails outside CI with `EUSAGE: Automatic provenance generation not
  supported for provider: null`. The script passes `--provenance=false`.
