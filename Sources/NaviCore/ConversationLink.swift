import Foundation

/// Deep links that open a session's conversation in the app hosting it.
///
/// - Claude desktop app: `claude://code/continue?session=local_<id>`. The app
///   keeps one JSON file per Code session (`local_<id>.json`) whose
///   `cliSessionId` is the Claude Code session ID Navi sees, for local and
///   SSH sessions alike.
/// - VS Code extension: `vscode://anthropic.claude-code/open?session=<id>`
///   (local sessions whose registry entry says `entrypoint: claude-vscode`).
///
/// Neither link is a documented API; both are what those apps register today,
/// so callers fall back to their old behaviour when this returns nil.
public enum ConversationLink {
    public static let desktopSessionsDir = NSString(
        string: "~/Library/Application Support/Claude/claude-code-sessions").expandingTildeInPath
    public static let registryDir = NSString(string: "~/.claude/sessions").expandingTildeInPath

    static let desktopIDPattern = try! NSRegularExpression(pattern: "^local_[A-Za-z0-9-]{1,64}$")

    public static func url(for session: SessionInfo,
                           desktopDir: String = desktopSessionsDir,
                           registryDir: String = registryDir) -> URL? {
        if let id = desktopSessionID(cliSessionID: session.id, in: desktopDir) {
            return desktopURL(id)
        }
        if session.isLocal, entrypoint(sessionID: session.id, pid: session.pid, in: registryDir) == "claude-vscode" {
            return vscodeURL(session.id)
        }
        return nil
    }

    static func desktopURL(_ id: String) -> URL? {
        var c = URLComponents(string: "claude://code/continue")!
        c.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "source", value: "navi")]
        return c.url
    }

    static func vscodeURL(_ sessionID: String) -> URL? {
        var c = URLComponents(string: "vscode://anthropic.claude-code/open")!
        c.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return c.url
    }

    /// The desktop app's `local_…` ID for a Claude Code session, newest
    /// non-archived match first. Files are only parsed when they mention the ID.
    static func desktopSessionID(cliSessionID: String, in dir: String) -> String? {
        guard !cliSessionID.isEmpty, let walker = FileManager.default.enumerator(atPath: dir) else { return nil }
        let needle = Data(cliSessionID.utf8)
        var best: (id: String, activity: Double)?
        while let rel = walker.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                  let data = FileManager.default.contents(atPath: "\(dir)/\(rel)"),
                  data.range(of: needle) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["cliSessionId"] as? String == cliSessionID,
                  obj["isArchived"] as? Bool != true,
                  let id = obj["sessionId"] as? String,
                  desktopIDPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
            else { continue }
            let activity = (obj["lastActivityAt"] as? Double) ?? 0
            if best == nil || activity > best!.activity { best = (id, activity) }
        }
        return best?.id
    }

    /// `entrypoint` from Claude Code's session registry (`<pid>.json`).
    static func entrypoint(sessionID: String, pid: pid_t, in dir: String) -> String? {
        func read(_ path: String) -> [String: Any]? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        if pid > 0, let d = read("\(dir)/\(pid).json"), d["sessionId"] as? String == sessionID {
            return d["entrypoint"] as? String
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
            if let d = read("\(dir)/\(name)"), d["sessionId"] as? String == sessionID {
                return d["entrypoint"] as? String
            }
        }
        return nil
    }
}
