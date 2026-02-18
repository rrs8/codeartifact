#!/bin/bash
set -euo pipefail

# Build and install dependencies from Maven Central
#
# Usage:
#   ./scripts/install-maven.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Building from Maven Central"
echo "=========================================="
echo ""

cd "$PROJECT_DIR"

# Clean previous build
echo "Cleaning previous build..."
mvn clean -q

# Build with default Maven Central
echo "Building with Maven Central..."
mvn package -DskipTests

echo ""
echo "=========================================="
echo "Build Complete"
echo "=========================================="

# Show dependency versions
echo ""
echo "Dependencies downloaded:"
mvn dependency:list -DincludeScope=runtime -q | grep ":.*:.*:" | sed 's/\[INFO\]//' | sort || true

echo ""
echo "To run the app:"
echo "  ./scripts/run.sh"
