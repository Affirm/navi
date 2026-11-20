import Testing
import Foundation
@testable import NaviCore

@Suite("TranscriptTitleCache")
struct TranscriptTitleTests {
    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! + "\n"
    }

    @Test func titlesPrecedenceAndIncrementalReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navi-titles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("-Users-me-readest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s1.jsonl")
        try (line(["type": "user", "message": ["content": "<command-name>/clear</command-name>"]])
             + line(["type": "user", "isCompactSummary": true, "message": ["content": "This session is being continued"]])
             + line(["type": "user", "message": ["content": "Son sürümü   çek"]])).write(to: file, atomically: true, encoding: .utf8)

        let cache = TranscriptTitleCache(projectsDir: root.path)
        #expect(cache.title(sessionID: "s1", cwd: "/Users/me/readest") == "Son sürümü çek")

        let h = try FileHandle(forWritingTo: file)
        h.seekToEndOfFile()
        h.write(Data(line(["type": "ai-title", "aiTitle": "Son sürüm pull işlemi"]).utf8))
        #expect(cache.title(sessionID: "s1", cwd: "/Users/me/readest") == "Son sürüm pull işlemi")
        h.write(Data(line(["type": "custom-title", "customTitle": "Readest release"]).utf8))
        h.write(Data(line(["type": "ai-title", "aiTitle": "Later AI"]).utf8))
        h.write(Data(#"{"type":"custom-title","customTi"#.utf8))
        #expect(cache.title(sessionID: "s1", cwd: "/elsewhere") == "Readest release")
        h.write(Data(#"tle":"Readest v2"}"#.utf8 + Data("\n".utf8)))
        try h.close()
        #expect(cache.title(sessionID: "s1", cwd: "/Users/me/readest") == "Readest v2")
        #expect(cache.title(sessionID: "missing", cwd: "/x") == "")
    }

    @Test func longPromptIsShortened() {
        var t = TranscriptTitleCache.Titles()
        TranscriptTitleCache.apply(Data(line(["type": "user", "message": ["content": [["type": "text", "text": String(repeating: "word ", count: 40)]]]]).utf8), to: &t)
        #expect(t.first.count == TranscriptTitleCache.promptTitleMax)
        #expect(t.first.hasSuffix("…"))
    }

    @Test func registryNameReplacesEventNameAndDerivedFallsBackToTitle() {
        var table: [SessionKey: SessionInfo] = [:]
        let key = SessionKey(sessionID: "s")
        SessionReconciler.merge([DiscoveredSession(sessionID: "s", pid: 1, alive: true, cwd: "/x/readest", title: "Son sürüm pull işlemi")],
                                origin: "", into: &table)
        table[key]!.sessionName = "readest-e3"  // e.g. from an event written by older hooks
        SessionReconciler.merge([DiscoveredSession(sessionID: "s", pid: 1, alive: true, cwd: "/x/readest", title: "Son sürüm pull işlemi")],
                                origin: "", into: &table)
        #expect(table[key]?.displayName(useSessionName: true) == "Son sürüm pull işlemi")
        SessionReconciler.merge([DiscoveredSession(sessionID: "s", pid: 1, alive: true, name: "Renamed")],
                                origin: "", into: &table)
        #expect(table[key]?.displayName(useSessionName: true) == "Renamed")
    }
}
