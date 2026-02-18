# JavaScript Demo App Scripts

Scripts to install dependencies and run the Node.js app from either public npm or CodeArtifact.

## Overview

Unlike Python's venv approach, npm uses a single `node_modules` directory. These scripts:
- Clear `node_modules` before installing
- Configure the registry (npm or CodeArtifact)
- Install fresh dependencies

To compare package versions between sources, run install then check versions before switching.

## Usage

### Option 1: Install and Run from public npm

```bash
./scripts/install-npm.sh
./scripts/run.sh
```

### Option 2: Install and Run from CodeArtifact

First, ensure CodeArtifact is set up and packages are synced:
```bash
./setup-codeartifact.sh
./sync-chainguard-packages-clean.sh
```

Then install and run:
```bash
./scripts/install-codeartifact.sh
./scripts/run.sh
```

## Scripts

| Script | Description |
|--------|-------------|
| `install-npm.sh` | Clears node_modules and installs from public npm |
| `install-codeartifact.sh` | Clears node_modules and installs from CodeArtifact |
| `run.sh` | Runs `server.js` and displays key package versions |

## Environment Variables

For CodeArtifact scripts (uses same defaults as `setup-codeartifact.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-2` | AWS region |
| `CODEARTIFACT_DOMAIN` | `my-npm-domain` | CodeArtifact domain |
| `CODEARTIFACT_REPO` | `my-npm-repo` | CodeArtifact repository |

For run script:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `5002` | Server port |

## Comparing Package Versions

To compare what's installed from each source:

```bash
# Install from npm and check versions
./scripts/install-npm.sh
npm ls --depth=0

# Install from CodeArtifact and check versions
./scripts/install-codeartifact.sh
npm ls --depth=0
```

Chainguard packages in CodeArtifact will show versions like `4.17.20` (same as npm) but are rebuilt with security enhancements.

## How It Works

### install-npm.sh
1. Removes existing `node_modules`
2. Clears npm cache
3. Resets registry to `https://registry.npmjs.org/`
4. Runs `npm install`

### install-codeartifact.sh
1. Removes existing `node_modules`
2. Clears npm cache
3. Gets CodeArtifact auth token via AWS CLI
4. Creates temporary `.npmrc` with CodeArtifact registry and auth
5. Runs `npm install`
6. Cleans up temporary `.npmrc`

## Testing the App

Once running, the server is available at http://localhost:5002

```bash
curl http://localhost:5002/api/package-json
```
