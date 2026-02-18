# CodeArtifact + Chainguard Libraries

Scripts to set up AWS CodeArtifact repositories with public registry fallback and sync packages from Chainguard Libraries.

## Overview

This repository provides scripts for three package ecosystems:

| Language | Package Format | Public Fallback | Chainguard Index |
|----------|---------------|-----------------|------------------|
| JavaScript | npm | npmjs.com | `libraries.cgr.dev/javascript/` |
| Python | PyPI | pypi.org | `libraries.cgr.dev/python/` and `libraries.cgr.dev/python-remediated/` |
| Java | Maven | Maven Central | `libraries.cgr.dev/java/` |

Each language directory contains three scripts:
- **`setup-codeartifact.sh`** - Creates CodeArtifact domain and repositories with public fallback
- **`sync-chainguard-packages.sh`** - Syncs packages from Chainguard to CodeArtifact
- **`cleanup-codeartifact.sh`** - Deletes CodeArtifact resources

## How It Works

1. **Setup** creates a CodeArtifact repository with an upstream connection to the public registry (npm, PyPI, or Maven Central)
2. **Sync** reads your dependency file, checks Chainguard Libraries for each package, and uploads found packages to CodeArtifact with origin controls that block upstream
3. Packages found in Chainguard are served from CodeArtifact (Chainguard version)
4. Packages not in Chainguard fall back to the public registry transparently

## Prerequisites

### AWS
- AWS CLI configured with permissions for CodeArtifact operations
- Appropriate IAM permissions for create/delete domain, repository, and package operations

### Chainguard Libraries
- Chainguard Libraries account with access credentials
- For Python/Java: credentials in `~/.netrc`:
  ```
  machine libraries.cgr.dev
      login <username>
      password <token>
  ```
- For JavaScript: `CGR_USERNAME` and `CGR_TOKEN` environment variables

### Language-Specific Tools
- **JavaScript**: `npm`, `jq`
- **Python**: `pip`, `twine`
- **Java**: `mvn`, `curl`

## Quick Start

### JavaScript
```bash
cd javascript
export CGR_USERNAME=your-username
export CGR_TOKEN=your-token

./setup-codeartifact.sh
./sync-chainguard-packages.sh
# ./cleanup-codeartifact.sh  # when done
```

### Python
```bash
cd python
./setup-codeartifact.sh
./sync-chainguard-packages.sh
# ./cleanup-codeartifact.sh  # when done
```

### Java
```bash
cd java
./setup-codeartifact.sh
./sync-chainguard-packages.sh
# ./cleanup-codeartifact.sh  # when done
```

## Environment Variables

Common to all languages:

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-2` | AWS region |
| `CODEARTIFACT_DOMAIN` | `my-{npm,pypi,maven}-domain` | CodeArtifact domain name |
| `CODEARTIFACT_REPO` | `my-{npm,pypi,maven}-repo` | Main repository name |
| `CODEARTIFACT_UPSTREAM_REPO` | varies | Upstream repository name |

See language-specific READMEs for additional options.

## Dependency Files

Each sync script reads from a standard dependency file:

| Language | File | Environment Variable |
|----------|------|---------------------|
| JavaScript | `package-lock.json` | `LOCKFILE` |
| Python | `requirements.txt` | `REQUIREMENTS_FILE` |
| Java | `pom.xml` | `POM_FILE` |

## Output

Each sync script produces:
- Packages uploaded to CodeArtifact (from Chainguard)
- `chainguard-not-found.txt` listing packages not available in Chainguard (these use public fallback)

## Python: Remediated Packages

The Python sync script checks two Chainguard indexes in order:
1. `python-remediated` - packages with security fixes applied by Chainguard
2. `python` - standard rebuilt/verified packages

This ensures you get remediated versions when available.

## Directory Structure

```
.
├── README.md
├── javascript/
│   ├── README.md
│   ├── setup-codeartifact.sh
│   ├── sync-chainguard-packages.sh
│   ├── sync-chainguard-packages-clean.sh
│   └── cleanup-codeartifact.sh
├── python/
│   ├── README.md
│   ├── setup-codeartifact.sh
│   ├── sync-chainguard-packages.sh
│   └── cleanup-codeartifact.sh
└── java/
    ├── README.md
    ├── setup-codeartifact.sh
    ├── sync-chainguard-packages.sh
    └── cleanup-codeartifact.sh
```

## License

[Add your license here]
