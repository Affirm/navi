import Testing
import Foundation
@testable import NaviCore

@Suite("FeatureFlags")
struct FeatureFlagsTests {
    private func uniqueName(_ prefix: String = "test-flag") -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    private func path(for name: String) -> String {
        "\(FeatureFlags.directory)/\(name)"
    }

    init() {
        FeatureFlags.ensureDirectory()
    }

    @Test func setEnabledCreatesFile() {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.set(name, enabled: true)
        #expect(FileManager.default.fileExists(atPath: path(for: name)))
    }

    @Test func setDisabledRemovesFile() {
        let name = uniqueName()
        FeatureFlags.set(name, enabled: true)
        FeatureFlags.set(name, enabled: false)
        #expect(!FileManager.default.fileExists(atPath: path(for: name)))
    }

    @Test func setEnabledIsIdempotent() {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.set(name, enabled: true)
        FeatureFlags.set(name, enabled: true)
        FeatureFlags.set(name, enabled: true)
        #expect(FileManager.default.fileExists(atPath: path(for: name)))
    }

    @Test func setDisabledOnAbsentFlagIsNoOp() {
        let name = uniqueName()
        FeatureFlags.set(name, enabled: false)
        #expect(!FileManager.default.fileExists(atPath: path(for: name)))
    }

    @Test func setEnabledOverwritesExistingConfigWithEmpty() {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.setConfig(name, config: ["timeout": 30])
        FeatureFlags.set(name, enabled: true)
        #expect(FileManager.default.fileExists(atPath: path(for: name)))
        #expect(FeatureFlags.readConfig(name) == nil, "expected file to be reset to empty")
    }

    @Test func setConfigWritesJSON() throws {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.setConfig(name, config: ["timeout": 120, "label": "hello"])
        let config = try #require(FeatureFlags.readConfig(name))
        #expect(config["timeout"] as? Int == 120)
        #expect(config["label"] as? String == "hello")
    }

    @Test func setConfigOverwritesExistingConfig() throws {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.setConfig(name, config: ["timeout": 30])
        FeatureFlags.setConfig(name, config: ["timeout": 120, "extra": "yes"])
        let config = try #require(FeatureFlags.readConfig(name))
        #expect(config["timeout"] as? Int == 120)
        #expect(config["extra"] as? String == "yes")
    }

    @Test func setConfigSupportsArrayValues() throws {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.setConfig(name, config: ["names": ["a", "b", "c"]])
        let config = try #require(FeatureFlags.readConfig(name))
        #expect(config["names"] as? [String] == ["a", "b", "c"])
    }

    @Test func setConfigSupportsNestedDict() throws {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.setConfig(name, config: ["nested": ["k": 1]])
        let config = try #require(FeatureFlags.readConfig(name))
        let nested = try #require(config["nested"] as? [String: Any])
        #expect(nested["k"] as? Int == 1)
    }

    @Test func setConfigWithNonSerializableValueIsNoOp() {
        // Regression: passing a non-JSON-serializable value (Date, Data,
        // non-String keys, etc.) used to raise an Objective-C NSException
        // that `try?` couldn't catch, crashing the app. CONTRIBUTING.md
        // documents setConfig as the API for configurable features, so a
        // future contributor passing a `@Published var someDate: Date`
        // through this method would have hit that crash.
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.setConfig(name, config: ["when": Date()])
        #expect(!FileManager.default.fileExists(atPath: path(for: name)))
    }

    @Test func readConfigReturnsNilWhenAbsent() {
        let name = uniqueName()
        #expect(FeatureFlags.readConfig(name) == nil)
    }

    @Test func readConfigReturnsNilForEmptyFile() {
        let name = uniqueName()
        defer { try? FileManager.default.removeItem(atPath: path(for: name)) }
        FeatureFlags.set(name, enabled: true)
        #expect(FeatureFlags.readConfig(name) == nil)
    }

    @Test func ensureDirectoryCreatesPath() {
        FeatureFlags.ensureDirectory()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: FeatureFlags.directory, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test func ensureDirectorySetsOwnerOnlyPermissions() throws {
        FeatureFlags.ensureDirectory()
        let attrs = try FileManager.default.attributesOfItem(atPath: FeatureFlags.directory)
        let perms = try #require(attrs[.posixPermissions] as? Int)
        #expect(perms == 0o700)
    }
}
