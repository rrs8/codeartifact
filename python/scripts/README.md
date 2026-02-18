# Python Demo App Scripts

Scripts to install dependencies and run the Flask app from either PyPI or CodeArtifact.

## Overview

These scripts use separate virtual environments to avoid conflicts:
- `.venv-pypi/` - dependencies from public PyPI
- `.venv-codeartifact/` - dependencies from AWS CodeArtifact (with Chainguard packages)

Both venvs can coexist, allowing quick comparison between package sources.

## Usage

### Option 1: Install and Run from PyPI

```bash
./scripts/install-pypi.sh
./scripts/run-pypi.sh
```

### Option 2: Install and Run from CodeArtifact

First, ensure CodeArtifact is set up and packages are synced:
```bash
./setup-codeartifact.sh
./sync-chainguard-packages.sh
```

Then install and run:
```bash
./scripts/install-codeartifact.sh
./scripts/run-codeartifact.sh
```

## Scripts

| Script | Description |
|--------|-------------|
| `install-pypi.sh` | Creates `.venv-pypi` and installs from public PyPI |
| `install-codeartifact.sh` | Creates `.venv-codeartifact` and installs from CodeArtifact |
| `run-pypi.sh` | Runs `app.py` using the PyPI venv |
| `run-codeartifact.sh` | Runs `app.py` using the CodeArtifact venv |

## Environment Variables

For CodeArtifact scripts (uses same defaults as `setup-codeartifact.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-2` | AWS region |
| `CODEARTIFACT_DOMAIN` | `my-pypi-domain` | CodeArtifact domain |
| `CODEARTIFACT_REPO` | `my-pypi-repo` | CodeArtifact repository |

For all scripts:

| Variable | Default | Description |
|----------|---------|-------------|
| `REQUIREMENTS_FILE` | `requirements.txt` | Path to requirements file |
| `PYTHON` | `python3` | Python executable |

## Verifying the Installation

Each run script displays the Flask version before starting. You can also check manually:

```bash
# PyPI version
source .venv-pypi/bin/activate
python -c "import flask; print(flask.__version__)"

# CodeArtifact version (may include +cgr suffix for Chainguard packages)
source .venv-codeartifact/bin/activate
python -c "import flask; print(flask.__version__)"
```

## Testing the App

Once running, test the endpoint:
```bash
curl http://localhost:5000/
```

Response includes the Flask version:
```json
{"flask_version": "2.3.3", "status": "ok"}
```
