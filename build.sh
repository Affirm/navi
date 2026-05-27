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

# Pin SHA-256 of every Swift source file under Sources/. Carries forward the
# intent of the v1.1.8 main.swift pin into the SPM layout: any legitimate
# edit to a source file must also bump its line in this table, surfacing the
# change to PR reviewers as a build.sh diff alongside the source change. A
# count check below prevents new files from sneaking in unchecked.
#
# TODO(future): replace this with CI-published, signed Navi.app artifacts.
# Per-file checksums are a stopgap that becomes maintenance burden once the
# source tree grows; proper artifact publishing from CI is the long-term
# answer to "is the Navi.app I'm running the one Affirm vetted?".
EXPECTED_SOURCE_CHECKSUMS=$(cat <<'EOF'
Sources/Navi/EnrichmentService.swift              a205c1575da27e0b482f9ced7ae9a65a350347e814c25392cc1855e85fdf1d13
Sources/Navi/FloatingWindowManager.swift          2dfe3edab612337694e437f7f4661371413221c220a5d928524bedd76091eae3
Sources/Navi/FontScale.swift                      846291c663cdf53daa9eb2247bdd3850269e726e6887aa90b3023b8e8efeab69
Sources/Navi/MenuBarManager.swift                 d763cacf5fbb574cec2a90461990c631c45a1b9b2be1eb026bdacf15d0995b99
Sources/Navi/NaviApp.swift                        8266bfb829814fc9bca25d0c370cf983e5ae8cdb0ec2c5f7ef4d0453515311df
Sources/Navi/PastelPalette.swift                  27327a7bca05a1d5683df81ea993acd0254c7ea1d4b45ca2e55da238c94cc293
Sources/Navi/Views/ContentView.swift              3ed2c01c56ae36765957e2a61a97c59864432c7217b7661c799eebb704779c74
Sources/Navi/Views/EventRow.swift                 3a7890296fa2586ee6de82d67220a39bac2ba41fdc6856d698ea78a445c703ad
Sources/Navi/Views/FlowLayout.swift               58848e9059bdc13d77d803fda4d96f80dfe9ab6fca40b13ec46b8bec9738c9ad
Sources/Navi/Views/SessionSection.swift           b894e126b90aa0e0e3d91bce3e4af315972c8712395b3988faaf4acdf4bd8401
Sources/Navi/Views/WindowAccessor.swift           2e3a59384cd4f21985d97ab34805db3ae988650d9a007b395d7a7efd303ab630
Sources/NaviCore/EventMonitor.swift               9527624c89c3e23312a99272d58de70fe0da5a9a8d4d09f58183cd7ae22c1a81
Sources/NaviCore/FeatureFlags.swift               e9d8c847c2f04ea128caab971b75a49cda59e41cc323017619cc84e29e690228
Sources/NaviCore/Helpers.swift                    836c8e9a715e22d8579c135f21ec9d4569923ce47ebcdfce3b5a6646946a6199
Sources/NaviCore/Logging.swift                    a414811c7a757681ea9f725a34930c32f0de8c8eab4f1352ba56398b19caeb2a
Sources/NaviCore/Models/GitInfo.swift             b5a95e8be176b17cb67c5726923d9af0eeac028c3d129ecd1793fd2d5013c46e
Sources/NaviCore/Models/NaviEvent.swift           e48aa05310d0f57a56363e908400af1d78acbce5969e2cdfc6b65004690c7534
Sources/NaviCore/Models/PRInfo.swift              0d5f2f8384508b182eb4ca827ecac51004094a8484b384b117f6a3d2ba329d49
Sources/NaviCore/Models/SessionGroup.swift        a34f92fd4a2ded929ad16fedbd9d3c7f29df7cc4e2c80c1440bbe7355f2df8ea
Sources/NaviCore/Models/SessionInfo.swift         5775e9a713dc6eaba9a951689ad131cc5b6265e1a18edf48c3a8012ab036a66f
Sources/NaviCore/Models/SessionStatus.swift       c0a90ed97250e23e362a61397b7525fee1b0646330de805528dc2c77e53d1d63
Sources/NaviCore/Models/TranscriptInfo.swift      cf5a3e4c07123156dc31187ac1a62e4eed4126f0ba85fb32bd0daab051d4ffcb
Sources/NaviCore/SessionEnrichmentProvider.swift  b18d9987764d8d4206a765b7a54cc12cd808a562228989d0b68db990149f4ea7
Sources/NaviCore/TerminalFocus.swift              075648d92cdc22d72b980a4cfb47ca114bbb1fe2c66c4a16643a2216a93c3f89
Sources/NaviCore/Version.swift                    65aaaed7d867af60613890557bea62ea5bb9685d942cd3f958c955daa88e5f61
EOF
)

expected_count=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    expected_count=$((expected_count + 1))
    relative_path=$(echo "$line" | awk '{print $1}')
    expected_sha=$(echo "$line" | awk '{print $2}')
    actual_sha=$(shasum -a 256 "$DIR/$relative_path" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$actual_sha" ]; then
        echo "Navi build aborted: missing pinned source file: $relative_path" >&2
        exit 1
    fi
    if [ "$actual_sha" != "$expected_sha" ]; then
        cat >&2 <<EOF
Navi build aborted: $relative_path checksum mismatch.

Expected SHA-256: $expected_sha
Actual SHA-256:   $actual_sha

If you intentionally edited this file, update the corresponding line in
build.sh's EXPECTED_SOURCE_CHECKSUMS table and commit that change in the
same PR. The same intent as the v1.1.8 main.swift pin: any source edit
must surface as a build.sh diff alongside the source change.
EOF
        exit 1
    fi
done <<EOF
$EXPECTED_SOURCE_CHECKSUMS
EOF

# Catch additions: count actual .swift files under Sources/ and compare. A
# new file would have no matching checksum, but the per-file loop above only
# verifies known paths. The count check makes a sneaked-in source file fail
# the build before it can run.
actual_count=$(find "$DIR/Sources" -name "*.swift" -type f | wc -l | tr -d ' ')
if [ "$actual_count" != "$expected_count" ]; then
    echo "Navi build aborted: unexpected number of Swift source files." >&2
    echo "Expected $expected_count files in EXPECTED_SOURCE_CHECKSUMS, found $actual_count under Sources/." >&2
    echo "If you added or removed a source file, update the table in build.sh." >&2
    exit 1
fi

echo "Building Navi..." >&2
echo "== Build environment ==" >&2
echo "macOS:     $(sw_vers -productVersion) ($(uname -m))" >&2
echo "Developer: $(xcode-select -p 2>/dev/null || echo '(not configured)')" >&2
echo "Swift:     $(xcrun -sdk macosx swift --version 2>&1 | head -1)" >&2
echo "SDK:       $(xcrun -sdk macosx --show-sdk-version 2>/dev/null) at $(xcrun -sdk macosx --show-sdk-path 2>/dev/null)" >&2
echo "=======================" >&2

# Compile via SPM (Sources/Navi + Sources/NaviCore).
( cd "$DIR" && xcrun -sdk macosx swift build -c release --product Navi )

# Assemble the .app bundle around the SPM-built binary. macOS GUI apps need
# this structure for Info.plist (LSUIElement, etc.) to be honored.
mkdir -p "$MACOS"
cp "$DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$DIR/.build/release/Navi" "$BINARY"

# Remove quarantine/provenance if present
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Record which version we just built
echo "$TARGET_VERSION" > "$BUILT_VERSION_FILE"

# Signal running Navi to show a restart banner with the new version
mkdir -p /tmp/navi
echo "$TARGET_VERSION" > /tmp/navi/needs-restart

echo "Built: $APP_BUNDLE" >&2
