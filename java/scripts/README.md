# Java Demo App Scripts

Scripts to build and run the Java application from either Maven Central or CodeArtifact.

## Overview

These scripts:
- Build the project with Maven using either Maven Central or CodeArtifact as the repository
- Copy dependencies to `target/libs/` for runtime
- Run the application with the correct classpath

Maven caches dependencies in `~/.m2/repository`. To force re-download from a different source, you may need to clear the local cache for specific artifacts.

## Usage

### Option 1: Build and Run from Maven Central

```bash
./scripts/install-maven.sh
./scripts/run.sh
```

### Option 2: Build and Run from CodeArtifact

First, ensure CodeArtifact is set up and packages are synced:
```bash
./setup-codeartifact.sh
./sync-chainguard-packages.sh
```

Then build and run:
```bash
./scripts/install-codeartifact.sh
./scripts/run.sh
```

## Scripts

| Script | Description |
|--------|-------------|
| `install-maven.sh` | Builds project using Maven Central |
| `install-codeartifact.sh` | Builds project using CodeArtifact |
| `run.sh` | Runs the application JAR with dependencies |

## Environment Variables

For CodeArtifact scripts (uses same defaults as `setup-codeartifact.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-2` | AWS region |
| `CODEARTIFACT_DOMAIN` | `my-maven-domain` | CodeArtifact domain |
| `CODEARTIFACT_REPO` | `my-maven-repo` | CodeArtifact repository |

## Comparing Dependencies

Maven caches downloaded artifacts in `~/.m2/repository`. To verify which repository artifacts came from:

```bash
# Check when an artifact was last downloaded
ls -la ~/.m2/repository/com/fasterxml/jackson/core/jackson-databind/2.15.3/

# View dependency tree
mvn dependency:tree
```

To force re-download from CodeArtifact:
```bash
# Delete specific artifacts from local cache
rm -rf ~/.m2/repository/com/fasterxml/jackson

# Then rebuild
./scripts/install-codeartifact.sh
```

## How It Works

### install-maven.sh
1. Runs `mvn clean`
2. Runs `mvn package` with default settings (uses Maven Central)
3. Dependencies are copied to `target/libs/`

### install-codeartifact.sh
1. Gets CodeArtifact auth token via AWS CLI
2. Creates temporary `settings.xml` with CodeArtifact repository and credentials
3. Runs `mvn clean`
4. Runs `mvn package -s settings.xml`
5. Cleans up temporary settings file

### run.sh
1. Finds the built JAR in `target/`
2. Runs with classpath including `target/libs/*`

## Testing the App

Once running, the server is available at http://localhost:5001

```bash
curl http://localhost:5001/health
curl http://localhost:5001/api/dependencies
```

## Notes

- Java 17+ is required
- The application uses Java's built-in HTTP server (com.sun.net.httpserver)
- Dependencies (Jackson, SLF4J) are minimal but demonstrate the CodeArtifact workflow
