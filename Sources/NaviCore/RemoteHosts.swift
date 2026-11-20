import Foundation

/// One remote host the user explicitly added. `alias` is what is passed to
/// `ssh`: a `Host` alias from ~/.ssh/config or a manual `user@host`. It doubles
/// as the session/event `origin`.
public struct RemoteHostConfig: Codable, Hashable, Identifiable {
    public var alias: String
    public var enabled: Bool

    public init(alias: String, enabled: Bool = true) {
        self.alias = alias
        self.enabled = enabled
    }

    public var id: String { alias }

    /// SSH destinations are restricted to a conservative character set and may
    /// not start with "-", so an alias can never be parsed as an ssh option
    /// (e.g. `-oProxyCommand=...`). Covers `Host` aliases, `host`, `user@host`
    /// and IPv4 addresses; for ports or IPv6 literals add a `Host` entry to
    /// ~/.ssh/config and use its alias.
    public static func isValidAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 255, !alias.hasPrefix("-") else { return false }
        return alias.range(of: #"^[A-Za-z0-9_.@-]+$"#, options: .regularExpression) != nil
            && alias.filter { $0 == "@" }.count <= 1
            && !alias.hasSuffix("@") && !alias.hasPrefix("@")
    }
}

/// Persistence for the remote-hosts feature: the host list lives in
/// UserDefaults (`NaviExp.RemoteHosts`) and is mirrored to the
/// `/tmp/navi/features/remote-hosts` flag file as JSON while enabled.
public enum RemoteHostsSettings {
    public static let flagName = "remote-hosts"
    public static let enabledKey = "NaviExp.RemoteHostsEnabled"
    public static let hostsKey = "NaviExp.RemoteHosts"

    public static func loadHosts(from defaults: UserDefaults = .standard) -> [RemoteHostConfig] {
        guard let data = defaults.data(forKey: hostsKey),
              let hosts = try? JSONDecoder().decode([RemoteHostConfig].self, from: data)
        else { return [] }
        return dedupe(hosts.filter { RemoteHostConfig.isValidAlias($0.alias) })
    }

    public static func saveHosts(_ hosts: [RemoteHostConfig], to defaults: UserDefaults = .standard) {
        let clean = dedupe(hosts.filter { RemoteHostConfig.isValidAlias($0.alias) })
        if let data = try? JSONEncoder().encode(clean) {
            defaults.set(data, forKey: hostsKey)
        }
    }

    /// Flag-file config: `{"hosts":[{"alias":..,"enabled":..}]}`.
    public static func flagConfig(for hosts: [RemoteHostConfig]) -> [String: Any] {
        ["hosts": hosts.map { ["alias": $0.alias, "enabled": $0.enabled] as [String: Any] }]
    }

    /// Write (enabled) or remove (disabled) the feature flag file.
    public static func syncFlag(enabled: Bool, hosts: [RemoteHostConfig]) {
        if enabled {
            FeatureFlags.setConfig(flagName, config: flagConfig(for: hosts))
        } else {
            FeatureFlags.set(flagName, enabled: false)
        }
    }

    private static func dedupe(_ hosts: [RemoteHostConfig]) -> [RemoteHostConfig] {
        var seen = Set<String>()
        return hosts.filter { seen.insert($0.alias).inserted }
    }
}

/// Builds the command line that starts the relay on a host.
public enum RelayCommand {
    /// Feature flags the relay may mirror onto the server (must match
    /// MIRRORABLE_FEATURES in hooks/relay.py).
    public static let mirrorableFeatures = ["auto-dismiss", "session-status", "session-names"]

    /// The remote shell command: the embedded relay source is passed as a
    /// base64 argument (survives any quoting) and exec'd by python3, keeping
    /// stdin free as the control channel. Only [A-Za-z0-9+/=,-] reach the
    /// remote shell, all inside single quotes or as bare safe words.
    public static func remoteShellCommand(features: [String], source: String = RelaySource.python + "\n") -> String {
        let b64 = Data(source.utf8).base64EncodedString()
        var cmd = "python3 -c 'import base64;exec(base64.b64decode(\"\(b64)\"))'"
        let flags = features.filter { mirrorableFeatures.contains($0) }
        if !flags.isEmpty {
            cmd += " --features " + flags.joined(separator: ",")
        }
        return cmd
    }

    /// Default SSH transport arguments for `/usr/bin/ssh`. BatchMode means a
    /// host-key or passphrase prompt fails instead of hanging; `--` ends option
    /// parsing before the (already validated) destination.
    public static func sshArguments(alias: String, remoteCommand: String) -> [String] {
        [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "--", alias, remoteCommand,
        ]
    }
}

/// Turns ssh/relay failures into something a user can act on.
public enum RemoteErrorHint {
    public static func describe(alias: String, exitCode: Int32, stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("host key verification failed")
            || lower.contains("permission denied")
            || lower.contains("passphrase")
            || lower.contains("no more authentication methods")
            || lower.contains("too many authentication failures") {
            return "SSH needs interaction (host key or passphrase). Run `ssh \(alias)` once in Terminal, then retry."
        }
        if lower.contains("could not resolve hostname") {
            return "Unknown host \(alias). Check ~/.ssh/config or the address."
        }
        if lower.contains("connection refused") || lower.contains("timed out")
            || lower.contains("no route to host") || lower.contains("network is unreachable") {
            return "Can't reach \(alias): \(lastLine(text))"
        }
        if lower.contains("python3") && (lower.contains("not found") || lower.contains("no such file")) {
            return "python3 is not installed (or not on PATH) on \(alias)."
        }
        if text.isEmpty {
            return "Connection to \(alias) closed (exit \(exitCode))."
        }
        return lastLine(text)
    }

    private static func lastLine(_ text: String) -> String {
        let line = text.split(separator: "\n").last.map(String.init) ?? text
        return String(line.prefix(300))
    }
}

/// Exponential reconnect backoff: 1s, 2s, 4s ... capped at 60s.
public struct Backoff: Equatable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public private(set) var attempt = 0

    public init(base: TimeInterval = 1, cap: TimeInterval = 60) {
        self.base = base
        self.cap = cap
    }

    /// Delay before the next attempt; advances the attempt counter.
    public mutating func next() -> TimeInterval {
        let delay = min(cap, base * pow(2, Double(min(attempt, 30))))
        attempt += 1
        return delay
    }

    public mutating func reset() { attempt = 0 }
}
