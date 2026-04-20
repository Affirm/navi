#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$DIR/Navi.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
BINARY="$MACOS/Navi"
BUILT_VERSION_FILE="$CONTENTS/built-version"

# Read the target version from plugin.json
TARGET_VERSION=$(sed -n 's/.*"version".*"\([^"]*\)".*/\1/p' "$DIR/.claude-plugin/plugin.json")

# Skip if already built for this version
if [ -x "$BINARY" ] && [ -f "$BUILT_VERSION_FILE" ] && [ "$(cat "$BUILT_VERSION_FILE")" = "$TARGET_VERSION" ]; then
    exit 0
fi

echo "Building Navi..." >&2

mkdir -p "$MACOS"
cp "$DIR/Info.plist" "$CONTENTS/Info.plist"

swiftc \
    -parse-as-library \
    -swift-version 5 \
    -O \
    -o "$BINARY" \
    "$DIR/main.swift" \
    -framework SwiftUI \
    -framework AppKit

# Remove quarantine/provenance if present
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Record which version we just built
echo "$TARGET_VERSION" > "$BUILT_VERSION_FILE"

# Signal running Navi to show a restart banner with the new version
mkdir -p /tmp/navi
echo "$TARGET_VERSION" > /tmp/navi/needs-restart

echo "Built: $APP_BUNDLE" >&2
