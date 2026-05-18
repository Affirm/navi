import Testing
import Foundation
@testable import NaviCore

@Suite("naviCurrentVersion")
struct VersionTests {
    @Test func isNotEmpty() {
        #expect(!naviCurrentVersion.isEmpty)
    }

    @Test func looksLikeSemver() {
        // Expect "MAJOR.MINOR.PATCH" with all numeric components.
        let parts = naviCurrentVersion.split(separator: ".")
        #expect(parts.count == 3)
        for part in parts {
            #expect(Int(part) != nil, "version part '\(part)' is not numeric")
        }
    }

    /// Drift guard: the runtime constant should match plugin.json. The build
    /// script reads plugin.json's version into Navi.app, so a mismatch leads
    /// to confusing restart-banner behavior.
    @Test func matchesPluginJSON() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent(".claude-plugin/plugin.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let pluginVersion = try #require(dict["version"] as? String)
                #expect(naviCurrentVersion == pluginVersion,
                        "naviCurrentVersion (\(naviCurrentVersion)) does not match plugin.json (\(pluginVersion))")
                return
            }
            dir.deleteLastPathComponent()
        }
        Issue.record("Could not locate .claude-plugin/plugin.json relative to test source")
    }
}
