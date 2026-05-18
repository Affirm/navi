import Foundation

/// File-based feature flag storage at `/tmp/navi/features/<name>`. Hooks read
/// these files to skip work for disabled features without restarting Claude
/// Code sessions. A file's existence means "enabled"; its contents (if any)
/// carry JSON configuration.
public enum FeatureFlags {
    public static let directory = "/tmp/navi/features"

    /// Write a boolean feature flag (empty file = enabled, absent = disabled).
    /// For features with configuration, use `setConfig` instead.
    public static func set(_ name: String, enabled: Bool) {
        let path = "\(directory)/\(name)"
        if enabled {
            FileManager.default.createFile(atPath: path, contents: nil)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Write a feature flag with JSON configuration. The file's existence means
    /// enabled; its contents carry config that hooks can read.
    public static func setConfig(_ name: String, config: [String: Any]) {
        // JSONSerialization raises an Objective-C NSException (not a Swift
        // Error) when given a non-serializable value like a Date — `try?`
        // wouldn't catch that. Validate up front so misuse silently no-ops
        // instead of crashing.
        guard JSONSerialization.isValidJSONObject(config) else { return }
        let path = "\(directory)/\(name)"
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return }
        let tmp = "\(path).tmp"
        FileManager.default.createFile(atPath: tmp, contents: data)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    /// Read JSON configuration from a feature flag file. Returns nil if the
    /// feature is disabled (file absent) or has no config (empty file).
    public static func readConfig(_ name: String) -> [String: Any]? {
        let path = "\(directory)/\(name)"
        guard let data = FileManager.default.contents(atPath: path),
              !data.isEmpty,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    /// Ensure the features directory exists with owner-only permissions.
    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory)
    }
}
