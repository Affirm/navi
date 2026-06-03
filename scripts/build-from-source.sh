#!/bin/bash
set -euo pipefail

# Build Navi.app from source using the validated reproducibility recipe.
# Used by CI in release.yml AND by contributors who want a local build
# (e.g. when testing source changes before publishing a release).
#
# Two builds of the same source tree on the same toolchain produce
# bit-identical output; release.yml's verify job depends on this.
#
# Usage: scripts/build-from-source.sh <output-dir>
# Produces:
#   <output-dir>/Navi.app
#   <output-dir>/Navi.app.zip

OUT="${1:-}"
if [ -z "$OUT" ]; then
    echo "Usage: $0 <output-dir>" >&2
    exit 1
fi

# Resolve to absolute path
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$OUT/Navi.app"

VERSION=$(sed -n 's/.*"version".*"\([^"]*\)".*/\1/p' "$DIR/.claude-plugin/plugin.json")

trap 'status=$?
      if [ "$status" -ne 0 ]; then
        echo "" >&2
        echo "Build failed. If you see a SwiftUI \"SDK is not supported by the compiler\" error," >&2
        echo "your Xcode Command Line Tools install is likely inconsistent." >&2
        echo "See README -> Troubleshooting." >&2
      fi' EXIT

rm -rf "$APP" "$OUT/Navi.app.zip" "$OUT/.build"
mkdir -p "$APP/Contents/MacOS"

echo "Building Navi v$VERSION..." >&2
echo "== Build environment ==" >&2
echo "macOS:     $(sw_vers -productVersion) ($(uname -m))" >&2
echo "Developer: $(xcode-select -p 2>/dev/null || echo '(not configured)')" >&2
echo "Swift:     $(xcrun -sdk macosx swift --version 2>&1 | head -1)" >&2
echo "SDK:       $(xcrun -sdk macosx --show-sdk-version 2>/dev/null) at $(xcrun -sdk macosx --show-sdk-path 2>/dev/null)" >&2
echo "=======================" >&2

# -Xlinker -reproducible: make two builds of identical inputs produce identical
# binaries (CI's verify job depends on this). ld-prime keeps a valid LC_UUID
# derived from a content hash, so the output stays bit-identical while remaining
# debuggable. We deliberately avoid -no_uuid: ld(1) warns that UUID-less binaries
# break the debugger and crash-reporting/symbolication tools, and a UUID-less
# x86_64 build won't load under Rosetta 2 (which keys its translation cache on
# the UUID). Requires the new linker (ld-prime, Xcode 15+); errors on older ld.
( cd "$DIR" && xcrun -sdk macosx swift build -c release \
    -Xlinker -reproducible \
    --product Navi \
    --build-path "$OUT/.build" )

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$OUT/.build/release/Navi" "$APP/Contents/MacOS/Navi"

# Strip debug info; ad-hoc codesign (both deterministic given identical inputs).
strip -S "$APP/Contents/MacOS/Navi"
codesign --sign - --force --deep "$APP"

# Clear any extended attrs that may have been set by xcode-select or codesign.
xattr -cr "$APP"

# Normalize mtimes so zip metadata doesn't drift between builds.
find "$APP" -exec touch -t 200001010000 {} +

# Plain zip with deterministic file ordering and -X to strip uid/gid/extra
# timestamps. ditto --sequesterRsrc was tried first but produces __MACOSX/
# entries with build-time mtimes that touch can't reach.
( cd "$OUT" && find Navi.app | LC_ALL=C sort | zip -X -@ Navi.app.zip > /dev/null )

# Drop the SPM build cache so it doesn't bloat the output directory.
rm -rf "$OUT/.build"

echo "" >&2
echo "Built: $APP" >&2
echo "Zip:   $OUT/Navi.app.zip" >&2
echo "SHA-256: $(shasum -a 256 "$OUT/Navi.app.zip" | cut -d' ' -f1)" >&2
