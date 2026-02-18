# Python CodeArtifact + Chainguard Libraries

Scripts to create an AWS CodeArtifact repository for Python/PyPI packages and sync Chainguard Libraries packages.

## Prerequisites

- AWS CLI configured with appropriate permissions
- `pip` and `twine` installed
- Chainguard Libraries credentials configured in `~/.netrc`:
  ```
  machine libraries.cgr.dev
      login <username>
      password <token>
  ```

## Scripts

### `setup-codeartifact.sh`

Creates the CodeArtifact domain, upstream repository with PyPI public connection, and main repository with fallback.

```bash
./setup-codeartifact.sh
```

### `sync-chainguard-packages.sh`

Reads `requirements.txt` and syncs packages from Chainguard Libraries to CodeArtifact:

1. For each package, checks the `python-remediated` index first
2. If not found, checks the regular `python` index
3. If found in either, downloads and uploads to CodeArtifact with origin controls set to block upstream (ensuring Chainguard packages take precedence)
4. If not found in Chainguard, records to `chainguard-not-found.txt` (these will fall back to public PyPI)

```bash
./sync-chainguard-packages.sh
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
| `CODEARTIFACT_DOMAIN` | `my-pypi-domain` | CodeArtifact domain name |
| `CODEARTIFACT_REPO` | `my-pypi-repo` | Main repository name |
| `CODEARTIFACT_UPSTREAM_REPO` | `pypi-public` | Upstream repository name |
| `REQUIREMENTS_FILE` | `requirements.txt` | Path to requirements file |
| `NOT_FOUND_FILE` | `chainguard-not-found.txt` | Output file for missing packages |
| `CGR_REMEDIATED_INDEX` | `https://libraries.cgr.dev/python-remediated/simple/` | Chainguard remediated index URL |
| `CGR_PYTHON_INDEX` | `https://libraries.cgr.dev/python/simple/` | Chainguard python index URL |

## Example Usage

```bash
# Set up CodeArtifact
export CODEARTIFACT_DOMAIN=my-domain
export CODEARTIFACT_REPO=my-repo
./setup-codeartifact.sh

# Sync packages from requirements.txt
./sync-chainguard-packages.sh

# Or with a different requirements file
REQUIREMENTS_FILE=requirements-dev.txt ./sync-chainguard-packages.sh

# Clean up when done
./cleanup-codeartifact.sh
```

## Chainguard Libraries Indexes

- **python-remediated**: Contains packages with security remediations applied by Chainguard
- **python**: Contains rebuilt/verified packages from Chainguard

The sync script checks `python-remediated` first to prefer remediated versions when available.
