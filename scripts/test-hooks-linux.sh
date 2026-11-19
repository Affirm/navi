#!/bin/bash
# Run the headless hook tests (Tests/hooks/test_headless.sh) in a throwaway
# Linux container. Requires Docker. Usage: scripts/test-hooks-linux.sh [image]
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-python:3.12-slim}"

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

# Only hooks/ is mounted (read-only) at /plugin/hooks: there is deliberately
# no build.sh or Navi.app beside it, so a hook that tries to build or launch
# the app fails the test.
exec docker run --rm \
    -v "$DIR/hooks:/plugin/hooks:ro" \
    -v "$DIR/Tests/hooks:/tests:ro" \
    "$IMAGE" bash /tests/test_headless.sh
