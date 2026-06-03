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

# Cryptographic verification confirms the artifact was built by this repo's CI
# from a real commit, not just that its bits match a checksum an attacker may
# have published alongside. It needs the gh CLI and an authenticated token.
#
# We distinguish "couldn't COMPLETE verification" from "verification ran and
# FAILED", because only the latter is a tamper signal:
#   - gh missing / not logged in        -> SHA-256 integrity check only (warn)
#   - attestation verifies              -> strong guarantee, proceed
#   - can't complete (auth / network / Sigstore outage)
#                                       -> SHA-256 fallback (warn): the artifact
#                                          may be fine, we just can't reach or
#                                          authorize the verifier
#   - completes and fails (no attestation / bad signature)
#                                       -> ABORT: SHA-256 can't save us here, since
#                                          a swapped artifact can ship a matching
#                                          checksums.txt. Unknown errors also abort
#                                          (fail closed).
if ! command -v gh >/dev/null 2>&1; then
    echo "Verified: SHA-256 matches checksums.txt. (For stronger attestation-based verification, install the gh CLI and run 'gh auth login': https://cli.github.com/)" >&2
elif ! gh auth status >/dev/null 2>&1; then
    echo "Verified: SHA-256 matches checksums.txt. (For stronger attestation-based verification, run 'gh auth login'.)" >&2
else
    OWNER="${REPO_SLUG%/*}"
    if ATT_OUT=$(gh attestation verify "$TMP/$ZIP_NAME" --owner "$OWNER" 2>&1); then
        echo "Verified: SHA-256 matches checksums.txt; build provenance attestation OK (gh attestation verify --owner $OWNER)." >&2
    elif printf '%s' "$ATT_OUT" | grep -qiE 'HTTP (401|403)|bad credentials|unauthorized|forbidden|timed? ?out|i/o timeout|connection (refused|reset)|could not resolve|dial tcp|network is unreachable|TLS'; then
        cat >&2 <<EOF

Navi: skipping build-provenance attestation — the attestation API could not be
reached or the request was not authorized (an auth or network issue, not a
problem with the downloaded file). Falling back to the SHA-256 checksum match,
which already passed.

gh reported:
$ATT_OUT

Manual check:
  gh attestation verify "$TMP/$ZIP_NAME" --owner "$OWNER"
EOF
    else
        cat >&2 <<EOF

Navi install aborted: build-provenance attestation verification FAILED.

The SHA-256 matched checksums.txt, but the artifact's attestation could not be
verified — this can indicate a tampered release. SHA-256 alone can't protect you
here: an attacker who swaps the artifact can also swap checksums.txt.

gh reported:
$ATT_OUT

Investigate before retrying. Manual check:
  gh attestation verify "$TMP/$ZIP_NAME" --owner "$OWNER"
EOF
        exit 1
    fi
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
