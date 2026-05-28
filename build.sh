#!/bin/bash
set -euo pipefail

# Hook-time install entry point. Reads the target version from plugin.json,
# fetches the matching release artifact from the repo identified in
# plugin.json's "repository" field, verifies it, and extracts Navi.app
# into the plugin directory.
#
# Set NAVI_BUILD_FROM_SOURCE=1 to compile locally instead of fetching
# (for contributors testing source changes before publishing a release).

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$DIR/Navi.app"
BINARY="$APP_BUNDLE/Contents/MacOS/Navi"
BUILT_VERSION_FILE="$APP_BUNDLE/Contents/built-version"
PLUGIN_JSON="$DIR/.claude-plugin/plugin.json"

TARGET_VERSION=$(sed -n 's/.*"version".*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON")
REPO_URL=$(sed -n 's/.*"repository".*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON")
REPO_SLUG="${REPO_URL#https://github.com/}"
REPO_SLUG="${REPO_SLUG%/}"

# Contributor escape hatch: build locally from source rather than fetching.
if [ -n "${NAVI_BUILD_FROM_SOURCE:-}" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    bash "$DIR/scripts/build-from-source.sh" "$TMP" >&2
    rm -rf "$APP_BUNDLE"
    mv "$TMP/Navi.app" "$APP_BUNDLE"
    echo "$TARGET_VERSION" > "$BUILT_VERSION_FILE"
    mkdir -p /tmp/navi
    echo "$TARGET_VERSION" > /tmp/navi/needs-restart
    echo "Built from source: $APP_BUNDLE (v$TARGET_VERSION)" >&2
    exit 0
fi

# Short-circuit if Navi.app is already at the target version.
if [ -x "$BINARY" ] && [ -f "$BUILT_VERSION_FILE" ] && [ "$(cat "$BUILT_VERSION_FILE")" = "$TARGET_VERSION" ]; then
    exit 0
fi

RELEASE_TAG="v$TARGET_VERSION"
ZIP_NAME="Navi.app.zip"
CHECKSUMS_NAME="checksums.txt"
RELEASE_BASE="https://github.com/$REPO_SLUG/releases/download/$RELEASE_TAG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching Navi $RELEASE_TAG from $REPO_SLUG..." >&2

if ! curl -fL --retry 3 --silent --show-error -o "$TMP/$ZIP_NAME" "$RELEASE_BASE/$ZIP_NAME"; then
    cat >&2 <<EOF

Navi install aborted: could not download $RELEASE_BASE/$ZIP_NAME

Usual causes:
  - The release for $RELEASE_TAG has not been published yet (CI may still be running)
  - You are offline
  - The version in plugin.json ($TARGET_VERSION) does not have a corresponding release

To build from source instead: NAVI_BUILD_FROM_SOURCE=1 bash "$DIR/build.sh"
EOF
    exit 1
fi

if ! curl -fL --retry 3 --silent --show-error -o "$TMP/$CHECKSUMS_NAME" "$RELEASE_BASE/$CHECKSUMS_NAME"; then
    echo "Navi install aborted: could not download $RELEASE_BASE/$CHECKSUMS_NAME" >&2
    exit 1
fi

# Tamper / corruption check against the published checksums file.
EXPECTED_SHA=$(awk -v name="$ZIP_NAME" '$2 == name || $2 == "*" name { print $1; exit }' "$TMP/$CHECKSUMS_NAME")
if [ -z "$EXPECTED_SHA" ]; then
    echo "Navi install aborted: $ZIP_NAME not listed in published checksums.txt." >&2
    exit 1
fi
ACTUAL_SHA=$(shasum -a 256 "$TMP/$ZIP_NAME" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    cat >&2 <<EOF
Navi install aborted: SHA-256 mismatch for $ZIP_NAME.

Expected (from published checksums.txt): $EXPECTED_SHA
Actual:                                  $ACTUAL_SHA

The downloaded file does not match what CI published. Investigate before retrying.
EOF
    exit 1
fi

# Cryptographic verification when gh is available: confirms the artifact
# was built by this repo's CI from a real commit, not just that bits
# match a checksum that an attacker may have published alongside.
if command -v gh >/dev/null 2>&1; then
    OWNER="${REPO_SLUG%/*}"
    if gh attestation verify "$TMP/$ZIP_NAME" --owner "$OWNER" >/dev/null 2>&1; then
        echo "Verified: SHA-256 matches checksums.txt; build provenance attestation OK (gh attestation verify --owner $OWNER)." >&2
    else
        cat >&2 <<EOF

Navi install aborted: attestation verification failed.

The artifact's SHA matched checksums.txt, but the GitHub attestation
chain could not be verified. This may indicate a compromised release
or a transient Sigstore outage. Re-run with:

  gh attestation verify "$TMP/$ZIP_NAME" --owner "$OWNER"

for full output, and investigate before retrying.
EOF
        exit 1
    fi
else
    echo "Verified: SHA-256 matches checksums.txt. (Install the gh CLI for stronger attestation-based verification: https://cli.github.com/)" >&2
fi

# Extract into place.
rm -rf "$APP_BUNDLE"
( cd "$DIR" && unzip -q "$TMP/$ZIP_NAME" )
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "$TARGET_VERSION" > "$BUILT_VERSION_FILE"

# Signal a running Navi instance to show a restart banner with the new version.
mkdir -p /tmp/navi
echo "$TARGET_VERSION" > /tmp/navi/needs-restart

echo "Installed: $APP_BUNDLE (v$TARGET_VERSION)" >&2
