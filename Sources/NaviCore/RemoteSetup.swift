import Foundation

/// "Test connection": one SSH run that reports where claude and python3 are.
/// `bash -lc` because non-interactive SSH often lacks ~/.local/bin or the npm
/// bin dir on PATH.
public enum HostProbe {
    public static let remoteCommand =
        #"bash -lc 'echo "claude_path=$(command -v claude)"; echo "claude_version=$(claude --version 2>/dev/null | head -n1)"; echo "python3=$(command -v python3)"; echo "user=$(id -un)"'"#

    public struct Result: Equatable {
        public var claudePath = ""
        public var claudeVersion = ""
        public var python3Path = ""
        public var user = ""

        public init(claudePath: String = "", claudeVersion: String = "", python3Path: String = "", user: String = "") {
            self.claudePath = claudePath
            self.claudeVersion = claudeVersion
            self.python3Path = python3Path
            self.user = user
        }

        public var version: ClaudeVersion? { ClaudeVersion.parse(claudeVersion) }

        /// What blocks remote monitoring on this host, if anything.
        public var problems: [String] {
            var p: [String] = []
            if claudePath.isEmpty { p.append("Claude Code (`claude`) not found on PATH") }
            if python3Path.isEmpty { p.append("python3 not found on PATH (needed by the relay)") }
            return p
        }

        public var summary: String {
            var parts: [String] = []
            if !user.isEmpty { parts.append("user \(user)") }
            parts.append(claudePath.isEmpty ? "no claude" : "claude \(version?.description ?? claudeVersion)")
            parts.append(python3Path.isEmpty ? "no python3" : "python3 ok")
            return parts.joined(separator: " · ")
        }
    }

    public static func parse(_ stdout: String) -> Result {
        var r = Result()
        for line in stdout.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard kv.count == 2 else { continue }
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            switch kv[0] {
            case "claude_path": r.claudePath = value
            case "claude_version": r.claudeVersion = value
            case "python3": r.python3Path = value
            case "user": r.user = value
            default: break
            }
        }
        return r
    }
}

/// Claude Code semantic version, parsed from `claude --version` output.
public struct ClaudeVersion: Comparable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public static func parse(_ text: String) -> ClaudeVersion? {
        guard let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let n = text[r].split(separator: ".").compactMap { Int($0) }
        guard n.count == 3 else { return nil }
        return ClaudeVersion(n[0], n[1], n[2])
    }

    public static func < (a: ClaudeVersion, b: ClaudeVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// `claude plugin install --json` landed in 2.1.268.
    public static let installJSONMinimum = ClaudeVersion(2, 1, 268)
    public var supportsInstallJSON: Bool { self >= Self.installJSONMinimum }
}

/// Install / uninstall the Navi plugin on a remote host. Every step is shown
/// to the user (as the exact ssh command) before anything runs.
public enum RemoteInstall {
    public struct Step: Equatable {
        public var title: String
        /// Runs on the host inside `bash -lc '…'`. Must not contain `'`.
        public var command: String
        /// Parse `--json` output (last stdout line: {"outcome":"ok|failed","message":…}).
        public var parsesJSON = false
        /// Treat "already …" output as success (re-adding a marketplace).
        public var toleratesAlready = false
        /// Retry with this step if the CLI rejects `--json` (older Claude Code).
        public var fallback: [Step] = []

        public var remoteCommand: String { "bash -lc '\(command)'" }
    }

    public static let marketplaceSource = "Affirm/navi"
    public static let pluginID = "navi@navi"
    public static let offlineDir = "~/.navi/plugin"

    public static func installSteps(version: ClaudeVersion?) -> [Step] {
        [addMarketplace(marketplaceSource), install(version: version)]
    }

    /// After `uploadSpec` copied the plugin to ~/.navi/plugin.
    public static func offlineInstallSteps(version: ClaudeVersion?) -> [Step] {
        [addMarketplace(offlineDir), install(version: version)]
    }

    public static func uninstallSteps() -> [Step] {
        [Step(title: "Uninstall the Navi plugin",
              command: "claude plugin uninstall \(pluginID) --scope user")]
    }

    private static func addMarketplace(_ source: String) -> Step {
        Step(title: "Add the Navi marketplace",
             command: "claude plugin marketplace add \(source) --scope user",
             toleratesAlready: true)
    }

    private static func install(version: ClaudeVersion?) -> Step {
        let plain = Step(title: "Install the Navi plugin",
                         command: "claude plugin install \(pluginID) --scope user")
        // Unknown version: try --json and fall back if the CLI rejects it.
        guard version?.supportsInstallJSON ?? true else { return plain }
        var json = plain
        json.command += " --json"
        json.parsesJSON = true
        json.fallback = version == nil ? [plain] : []
        return json
    }

    /// The command line shown to the user for a step.
    public static func displayCommand(alias: String, step: Step) -> String {
        "ssh \(alias) \(step.remoteCommand)"
    }

    public static func spec(alias: String, step: Step, sshPath: String = "/usr/bin/ssh") -> RemoteLaunchSpec {
        RemoteLaunchSpec(executable: URL(fileURLWithPath: sshPath),
                         arguments: RelayCommand.sshArguments(alias: alias, remoteCommand: step.remoteCommand))
    }

    public struct Outcome: Equatable {
        public var ok: Bool
        public var message: String
        /// The CLI didn't understand an option: run the step's fallback.
        public var needsFallback = false
    }

    public static func interpret(step: Step, alias: String, output: ProcessRunner.Output) -> Outcome {
        let out = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.timedOut { return Outcome(ok: false, message: "Timed out") }
        if output.exitCode == 255 {  // ssh itself failed
            return Outcome(ok: false, message: RemoteErrorHint.describe(alias: alias, exitCode: 255, stderr: err))
        }
        let combined = (out + "\n" + err).lowercased()
        if step.parsesJSON {
            if let last = out.split(whereSeparator: \.isNewline).last,
               let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
               let outcome = obj["outcome"] as? String {
                let message = obj["message"] as? String ?? ""
                return Outcome(ok: outcome == "ok", message: message.isEmpty ? outcome : message)
            }
            if !step.fallback.isEmpty && output.exitCode != 0
                && (combined.contains("unknown option") || combined.contains("--json")) {
                return Outcome(ok: false, message: "Retrying without --json", needsFallback: true)
            }
        }
        if output.exitCode == 0 {
            return Outcome(ok: true, message: lastLine(out).isEmpty ? "Done" : lastLine(out))
        }
        if step.toleratesAlready && combined.contains("already") {
            return Outcome(ok: true, message: "Already added")
        }
        let detail = lastLine(err).isEmpty ? lastLine(out) : lastLine(err)
        return Outcome(ok: false, message: detail.isEmpty ? "Failed (exit \(output.exitCode))" : detail)
    }

    /// Offline fallback: stream this Mac's plugin directory (minus the
    /// macOS app bundle and build output) to ~/.navi/plugin on the host.
    /// Paths and alias are passed as positional args, never interpolated.
    public static let uploadRemoteCommand =
        "rm -rf ~/.navi/plugin.new && mkdir -p ~/.navi/plugin.new && tar -xzf - -C ~/.navi/plugin.new && rm -rf ~/.navi/plugin && mv ~/.navi/plugin.new ~/.navi/plugin"

    public static func uploadSpec(pluginDir: String, alias: String, sshPath: String = "/usr/bin/ssh") -> RemoteLaunchSpec {
        let remote = uploadRemoteCommand
        let script = #"COPYFILE_DISABLE=1 tar -C "$1" --exclude ./Navi.app --exclude ./.git --exclude ./.build --exclude ./out -czf - . | "$3" -T -o BatchMode=yes -o ConnectTimeout=10 -- "$2" "$4""#
        return RemoteLaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"),
                                arguments: ["-c", script, "sh", pluginDir, alias, sshPath, remote])
    }

    public static func uploadDisplayCommand(pluginDir: String, alias: String) -> String {
        "tar -C \(pluginDir) --exclude ./Navi.app --exclude ./.git --exclude ./.build --exclude ./out -czf - . | ssh \(alias) '\(uploadRemoteCommand)'"
    }

    /// The plugin checkout this Navi.app was installed from, if any: the
    /// app's parent (installed plugin) or grandparent (`./out/Navi.app` dev
    /// build) containing the marketplace manifest and hooks.
    public static func localPluginDir(appBundle: URL = Bundle.main.bundleURL,
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        var dir = appBundle.deletingLastPathComponent()
        for _ in 0..<2 {
            if fileExists(dir.appendingPathComponent(".claude-plugin/marketplace.json").path),
               fileExists(dir.appendingPathComponent("hooks/hook.sh").path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func lastLine(_ s: String) -> String {
        String((s.split(whereSeparator: \.isNewline).last.map(String.init) ?? "").prefix(300))
    }
}
