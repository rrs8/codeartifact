#!/bin/bash
set -euo pipefail

# Run the Java application
#
# Usage:
#   ./scripts/run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Find the built JAR
JAR_FILE=$(ls -1 target/*.jar 2>/dev/null | grep -v sources | grep -v javadoc | head -n1)

if [[ -z "$JAR_FILE" || ! -f "$JAR_FILE" ]]; then
    echo "Error: JAR file not found in target/"
    echo "Run ./scripts/install-maven.sh or ./scripts/install-codeartifact.sh first"
    exit 1
fi

echo "=========================================="
echo "Running Java app"
echo "=========================================="
echo "JAR: $JAR_FILE"

# Show dependency versions from libs directory
if [[ -d "target/libs" ]]; then
    echo ""
    echo "Dependencies in target/libs:"
    ls -1 target/libs/*.jar 2>/dev/null | xargs -I{} basename {} | head -10
    TOTAL=$(ls -1 target/libs/*.jar 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$TOTAL" -gt 10 ]]; then
        echo "  ... and $((TOTAL - 10)) more"
    fi
fi

echo ""
echo "Starting server at http://localhost:5001"
echo ""

# Run with classpath including dependencies
java -cp "$JAR_FILE:target/libs/*" com.chainguard.demo.DemoApplication
