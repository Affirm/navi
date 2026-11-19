import Foundation

/// Conversation titles from Claude Code transcripts
/// (`~/.claude/projects/<encoded cwd>/<sessionID>.jsonl`), for sessions on
/// this Mac. Mirrors `TitleCache` in hooks/relay.py, which does the same on
/// remote hosts.
///
/// Claude Code appends `{"type":"custom-title","customTitle":…}` (/rename) and
/// `{"type":"ai-title","aiTitle":…}` lines as titles change; the latest of
/// each wins, custom over AI, with the first real user prompt as a fallback.
/// Files are read incrementally: only bytes appended since the last call.
public final class TranscriptTitleCache {
    public static let titleMax = 120
    public static let promptTitleMax = 70
    static let tailBytes: UInt64 = 4 * 1024 * 1024
    static let readBytes = 8 * 1024 * 1024

    struct Titles: Equatable {
        var custom = ""
        var ai = ""
        var first = ""
        var best: String { !custom.isEmpty ? custom : (!ai.isEmpty ? ai : first) }
    }

    private struct State {
        var path: String
        var offset: UInt64
        var titles = Titles()
        var partial = Data()
        var skipLine: Bool
    }

    private let projectsDir: String
    private var states: [String: State] = [:]

    public init(projectsDir: String = NSString(string: "~/.claude/projects").expandingTildeInPath) {
        self.projectsDir = projectsDir
    }

    public func title(sessionID: String, cwd: String) -> String {
        let fm = FileManager.default
        if states[sessionID] == nil || !fm.fileExists(atPath: states[sessionID]!.path) {
            guard let path = find(sessionID: sessionID, cwd: cwd),
                  let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64
            else { return "" }
            let start = size > Self.tailBytes ? size - Self.tailBytes : 0
            states[sessionID] = State(path: path, offset: start, skipLine: start > 0)
        }
        readNew(sessionID)
        return states[sessionID]?.titles.best ?? ""
    }

    public func forget(except live: Set<String>) {
        states = states.filter { live.contains($0.key) }
    }

    private func find(sessionID: String, cwd: String) -> String? {
        let fm = FileManager.default
        let name = "\(sessionID).jsonl"
        if !cwd.isEmpty {
            let encoded = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
            let direct = "\(projectsDir)/\(encoded)/\(name)"
            if fm.fileExists(atPath: direct) { return direct }
        }
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for dir in dirs {
            let p = "\(projectsDir)/\(dir)/\(name)"
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private func readNew(_ sid: String) {
        guard var st = states[sid],
              let size = (try? FileManager.default.attributesOfItem(atPath: st.path))?[.size] as? UInt64
        else { return }
        if size < st.offset {  // truncated or rewritten: start over
            st = State(path: st.path, offset: 0, skipLine: false)
        }
        guard size > st.offset, let handle = FileHandle(forReadingAtPath: st.path) else {
            states[sid] = st
            return
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: st.offset)
        let data = (try? handle.read(upToCount: min(Int(size - st.offset), Self.readBytes))) ?? Data()
        st.offset += UInt64(data.count)
        var buffer = st.partial + data
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<nl]))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        st.partial = buffer.count > Self.readBytes ? Data() : buffer
        if st.skipLine, !lines.isEmpty {
            lines.removeFirst()
            st.skipLine = false
        }
        for line in lines { Self.apply(line, to: &st.titles) }
        states[sid] = st
    }

    private static let customMarker = Data(#""custom-title""#.utf8)
    private static let aiMarker = Data(#""ai-title""#.utf8)
    private static let userMarker = Data(#""user""#.utf8)

    /// Update titles from one transcript line.
    static func apply(_ line: Data, to titles: inout Titles) {
        let wantFirst = titles.first.isEmpty && line.range(of: userMarker) != nil
        guard line.range(of: customMarker) != nil || line.range(of: aiMarker) != nil || wantFirst,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        switch obj["type"] as? String {
        case "custom-title":
            if let t = obj["customTitle"] as? String { titles.custom = clean(t) }
        case "ai-title":
            if let t = obj["aiTitle"] as? String { titles.ai = clean(t) }
        default:
            if wantFirst { titles.first = firstPrompt(obj) }
        }
    }

    static func clean(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(titleMax))
    }

    /// Text of a real user prompt, shortened for use as a label; "" for tool
    /// results, meta lines, slash commands and compact summaries.
    static func firstPrompt(_ obj: [String: Any]) -> String {
        guard obj["type"] as? String == "user",
              obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true,
              obj["isCompactSummary"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return "" }
        var text = ""
        if let s = message["content"] as? String {
            text = s
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("This session is being continued") { return "" }
        if text.count > promptTitleMax {
            text = String(text.prefix(promptTitleMax - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }
}
