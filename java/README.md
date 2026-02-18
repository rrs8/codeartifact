# Java CodeArtifact + Chainguard Libraries

Scripts to create an AWS CodeArtifact repository for Maven packages and sync Chainguard Libraries packages.

## Prerequisites

- AWS CLI configured with appropriate permissions
- Maven (`mvn`) installed
- `curl` installed
- Chainguard Libraries credentials configured in `~/.netrc`:
  ```
  machine libraries.cgr.dev
      login <username>
      password <token>
  ```

## Scripts

### `setup-codeartifact.sh`

Creates the CodeArtifact domain, upstream repository with Maven Central connection, and main repository with fallback.

```bash
./setup-codeartifact.sh
```

### `sync-chainguard-packages.sh`

Reads `pom.xml` and syncs packages from Chainguard Libraries to CodeArtifact:

1. Parses dependencies from `pom.xml` (groupId, artifactId, version)
2. Checks if each artifact exists in Chainguard's Java index
3. If found, downloads and uploads to CodeArtifact with origin controls set to block upstream
4. If not found, records to `chainguard-not-found.txt` (these will fall back to Maven Central)

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
| `CODEARTIFACT_DOMAIN` | `my-maven-domain` | CodeArtifact domain name |
| `CODEARTIFACT_REPO` | `my-maven-repo` | Main repository name |
| `CODEARTIFACT_UPSTREAM_REPO` | `maven-central-public` | Upstream repository name |
| `POM_FILE` | `pom.xml` | Path to POM file |
| `NOT_FOUND_FILE` | `chainguard-not-found.txt` | Output file for missing packages |
| `CGR_MAVEN_INDEX` | `https://libraries.cgr.dev/java/` | Chainguard Java index URL |

## Example Usage

```bash
# Set up CodeArtifact
export CODEARTIFACT_DOMAIN=my-domain
export CODEARTIFACT_REPO=my-repo
./setup-codeartifact.sh

# Sync packages from pom.xml
./sync-chainguard-packages.sh

# Or with a different POM file
POM_FILE=submodule/pom.xml ./sync-chainguard-packages.sh

# Clean up when done
./cleanup-codeartifact.sh
```

## Maven Configuration

After running `setup-codeartifact.sh`, configure Maven to use CodeArtifact by adding to `~/.m2/settings.xml`:

```xml
<settings>
  <servers>
    <server>
      <id>codeartifact</id>
      <username>aws</username>
      <password>${env.CODEARTIFACT_AUTH_TOKEN}</password>
    </server>
  </servers>

  <profiles>
    <profile>
      <id>codeartifact</id>
      <repositories>
        <repository>
          <id>codeartifact</id>
          <url>https://DOMAIN-ACCOUNT.d.codeartifact.REGION.amazonaws.com/maven/REPO/</url>
        </repository>
      </repositories>
    </profile>
  </profiles>

  <activeProfiles>
    <activeProfile>codeartifact</activeProfile>
  </activeProfiles>
</settings>
```

Then set the auth token before running Maven:

```bash
export CODEARTIFACT_AUTH_TOKEN=$(aws codeartifact get-authorization-token \
    --domain $CODEARTIFACT_DOMAIN --region $AWS_REGION \
    --query authorizationToken --output text)

mvn install
```

## Notes

- Dependencies with variable versions (e.g., `${project.version}`) are skipped during sync
- The script parses the `<dependencies>` section of pom.xml; dependency management and plugin dependencies are not currently processed
- For multi-module projects, run the sync script against each module's pom.xml
