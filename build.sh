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

trap 'status=$?
      if [ "$status" -ne 0 ]; then
        echo "" >&2
        echo "Build failed. If you see a SwiftUI \"SDK is not supported by the compiler\" error," >&2
        echo "your Xcode Command Line Tools install is likely inconsistent." >&2
        echo "See README -> Troubleshooting." >&2
      fi' EXIT

echo "Building Navi..." >&2
echo "== Build environment ==" >&2
echo "macOS:     $(sw_vers -productVersion) ($(uname -m))" >&2
echo "Developer: $(xcode-select -p 2>/dev/null || echo '(not configured)')" >&2
echo "Swift:     $(xcrun -sdk macosx swift --version 2>&1 | head -1)" >&2
echo "SDK:       $(xcrun -sdk macosx --show-sdk-version 2>/dev/null) at $(xcrun -sdk macosx --show-sdk-path 2>/dev/null)" >&2
echo "=======================" >&2

mkdir -p "$MACOS"
cp "$DIR/Info.plist" "$CONTENTS/Info.plist"

xcrun -sdk macosx swiftc \
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
