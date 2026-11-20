#!/bin/bash
# Run the headless hook tests (Tests/hooks/test_headless.sh) and the relay
# tests (Tests/relay) in a throwaway Linux container. Requires Docker. Usage: scripts/test-hooks-linux.sh [image]
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-python:3.12-slim}"

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

# Only hooks/ is mounted (read-only) at /plugin/hooks: there is deliberately
# no build.sh or Navi.app beside it, so a hook that tries to build or launch
# the app fails the test.
# Relay tests run as an unprivileged user: they check ownership/permission
# handling, which root would bypass.
exec docker run --rm \
    -v "$DIR/hooks:/plugin/hooks:ro" \
    -v "$DIR/Tests/hooks:/tests:ro" \
    -v "$DIR/Tests/relay:/plugin/Tests/relay:ro" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    "$IMAGE" bash -c '
        bash /tests/test_headless.sh || exit $?
        echo
        echo "== relay.py tests =="
        setpriv --reuid=1000 --regid=1000 --init-groups env HOME=/home/tester \
            python3 -m unittest discover -s /plugin/Tests/relay
    '
