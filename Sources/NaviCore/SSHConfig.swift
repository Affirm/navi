import Foundation

/// File access used by the ssh config parser; injectable for tests.
public protocol SSHConfigFileSystem {
    func contents(of path: String) -> String?
    /// Expand a glob pattern to matching paths, sorted.
    func glob(_ pattern: String) -> [String]
}

public struct LocalSSHConfigFileSystem: SSHConfigFileSystem {
    public init() {}

    public func contents(of path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    public func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        var paths: [String] = []
        for i in 0..<Int(g.gl_pathc) {
            if let p = g.gl_pathv[i] { paths.append(String(cString: p)) }
        }
        return paths.sorted()
    }
}

/// Lists concrete `Host` aliases from the user's ssh config for the host
/// picker. Patterns (`*`, `?`, `!negated`) are skipped since they aren't
/// connectable names. `Include` is followed (relative paths resolve against
/// ~/.ssh, globs allowed), with a depth limit and cycle guard. Effective
/// settings (Match, ProxyJump, ...) are left to `ssh -G`.
public enum SSHConfigParser {
    public static func hostAliases(
        configPath: String? = nil,
        home: String = NSHomeDirectory(),
        fs: SSHConfigFileSystem = LocalSSHConfigFileSystem()
    ) -> [String] {
        let sshDir = (home as NSString).appendingPathComponent(".ssh")
        let path = configPath ?? (sshDir as NSString).appendingPathComponent("config")
        var aliases: [String] = []
        var seen = Set<String>()
        var visited = Set<String>()
        parse(path: path, sshDir: sshDir, home: home, fs: fs, depth: 0,
              visited: &visited, aliases: &aliases, seen: &seen)
        return aliases
    }

    private static func parse(path: String, sshDir: String, home: String, fs: SSHConfigFileSystem,
                              depth: Int, visited: inout Set<String>,
                              aliases: inout [String], seen: inout Set<String>) {
        guard depth <= 16, visited.insert(path).inserted, let text = fs.contents(of: path) else { return }
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (keyword, args) = tokenize(String(rawLine)) else { continue }
            switch keyword {
            case "host":
                for name in args where isConcreteAlias(name) && seen.insert(name).inserted {
                    aliases.append(name)
                }
            case "include":
                for arg in args {
                    var pattern = arg
                    if pattern.hasPrefix("~/") {
                        pattern = (home as NSString).appendingPathComponent(String(pattern.dropFirst(2)))
                    } else if !pattern.hasPrefix("/") {
                        pattern = (sshDir as NSString).appendingPathComponent(pattern)
                    }
                    for file in fs.glob(pattern) {
                        parse(path: file, sshDir: sshDir, home: home, fs: fs, depth: depth + 1,
                              visited: &visited, aliases: &aliases, seen: &seen)
                    }
                }
            default:
                continue
            }
        }
    }

    static func isConcreteAlias(_ name: String) -> Bool {
        !name.contains("*") && !name.contains("?") && !name.hasPrefix("!")
            && RemoteHostConfig.isValidAlias(name)
    }

    /// Split a config line into a lowercased keyword and its arguments.
    /// Handles `Keyword value`, `Keyword=value`, comments and double quotes.
    static func tokenize(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var sawKeyword = false
        for ch in trimmed {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes && ch == "#" && current.isEmpty { break }
            let isSep = ch == " " || ch == "\t" || (!sawKeyword && ch == "=")
            if isSep && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = ""; sawKeyword = true }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        // "Keyword = value" / "Keyword =value"
        if tokens.count > 1, tokens[1].hasPrefix("=") {
            let rest = String(tokens[1].dropFirst())
            if rest.isEmpty { tokens.remove(at: 1) } else { tokens[1] = rest }
        }
        guard let first = tokens.first else { return nil }
        return (first.lowercased(), Array(tokens.dropFirst()))
    }
}

/// The handful of `ssh -G <alias>` fields shown in the host picker.
public struct SSHEffectiveConfig: Equatable {
    public var hostname: String = ""
    public var user: String = ""
    public var port: String = ""
    public var proxyJump: String = ""

    public init(hostname: String = "", user: String = "", port: String = "", proxyJump: String = "") {
        self.hostname = hostname
        self.user = user
        self.port = port
        self.proxyJump = proxyJump
    }

    public static func parse(_ output: String) -> SSHEffectiveConfig {
        var c = SSHEffectiveConfig()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname": c.hostname = parts[1]
            case "user": c.user = parts[1]
            case "port": c.port = parts[1]
            case "proxyjump": c.proxyJump = parts[1] == "none" ? "" : parts[1]
            default: break
            }
        }
        return c
    }

    /// e.g. "me@10.0.0.5:2222 via bastion"
    public var summary: String {
        var s = user.isEmpty ? hostname : "\(user)@\(hostname)"
        if !port.isEmpty && port != "22" { s += ":\(port)" }
        if !proxyJump.isEmpty { s += " via \(proxyJump)" }
        return s
    }

    /// Spec for `ssh -G <alias>`: prints effective config without connecting.
    public static func resolveSpec(alias: String, sshPath: String = "/usr/bin/ssh") -> RemoteLaunchSpec {
        RemoteLaunchSpec(executable: URL(fileURLWithPath: sshPath), arguments: ["-G", "--", alias])
    }
}

/// Runs a short-lived process and collects its output.
public enum ProcessRunner {
    public struct Output: Equatable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    public static func run(_ spec: RemoteLaunchSpec, stdin: Data? = nil, timeout: TimeInterval = 30) async -> Output {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(spec, stdin: stdin, timeout: timeout))
            }
        }
    }

    public static func runSync(_ spec: RemoteLaunchSpec, stdin: Data? = nil, timeout: TimeInterval = 30) -> Output {
        let proc = Process()
        proc.executableURL = spec.executable
        proc.arguments = spec.arguments
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe
        do {
            try proc.run()
        } catch {
            return Output(exitCode: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            timedOut = true
            proc.terminate()
            done.wait()
        }
        group.wait()
        return Output(exitCode: proc.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      timedOut: timedOut)
    }
}
