import Testing
import Foundation
@testable import NaviCore

@Suite("ConversationLink")
struct ConversationLinkTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("navi-link-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

    private func info(_ sid: String, origin: String = "", pid: pid_t = 0) -> SessionInfo {
        SessionInfo(id: sid, projectName: "p", shortSession: sid, cwd: "/p", tty: "", sessionName: "",
                    pid: pid, lastActivity: Date(), origin: origin)
    }

    @Test func desktopSessionWinsAndNewestMatchIsUsed() throws {
        let desk = tempDir(), reg = tempDir()
        defer { try? FileManager.default.removeItem(at: desk); try? FileManager.default.removeItem(at: reg) }
        try write(["sessionId": "local_old", "cliSessionId": "abc", "lastActivityAt": 1.0],
                  to: desk.appendingPathComponent("a/b/local_old.json"))
        try write(["sessionId": "local_new", "cliSessionId": "abc", "lastActivityAt": 5.0],
                  to: desk.appendingPathComponent("a/b/local_new.json"))
        try write(["sessionId": "local_gone", "cliSessionId": "abc", "lastActivityAt": 9.0, "isArchived": true],
                  to: desk.appendingPathComponent("a/b/local_gone.json"))
        let url = ConversationLink.url(for: info("abc", origin: "ops"), desktopDir: desk.path, registryDir: reg.path)
        #expect(url?.absoluteString == "claude://code/continue?session=local_new&source=navi")
    }

    @Test func vscodeSessionsUseTheExtensionLink() throws {
        let desk = tempDir(), reg = tempDir()
        defer { try? FileManager.default.removeItem(at: desk); try? FileManager.default.removeItem(at: reg) }
        try write(["sessionId": "s-1", "entrypoint": "claude-vscode"], to: reg.appendingPathComponent("42.json"))
        #expect(ConversationLink.url(for: info("s-1", pid: 42), desktopDir: desk.path, registryDir: reg.path)?
            .absoluteString == "vscode://anthropic.claude-code/open?session=s-1")
        // Remote sessions never use the local registry.
        #expect(ConversationLink.url(for: info("s-1", origin: "ops", pid: 42), desktopDir: desk.path,
                                     registryDir: reg.path) == nil)
    }

    @Test func remoteControlSessionsOpenByBridgeID() throws {
        let desk = tempDir(), reg = tempDir()
        defer { try? FileManager.default.removeItem(at: desk); try? FileManager.default.removeItem(at: reg) }
        var remote = info("r", origin: "ops")
        remote.remoteControlID = "session_01AuM4A8k5d4"
        #expect(ConversationLink.url(for: remote, desktopDir: desk.path, registryDir: reg.path)?
            .absoluteString == "claude://code/session_01AuM4A8k5d4")
        remote.remoteControlID = "session_x/../y"
        #expect(ConversationLink.url(for: remote, desktopDir: desk.path, registryDir: reg.path) == nil)
    }

    @Test func heartbeatPassesBridgeIDThrough() {
        let line = #"{"kind":"heartbeat","live":["s"],"sessions":[{"sessionId":"s","pid":1,"bridgeSessionId":"session_01Ab"}]}"#
        guard case .heartbeat(_, let sessions, _, _)? = RemoteMessage.parse(Data(line.utf8)) else {
            Issue.record("not a heartbeat"); return
        }
        #expect(sessions.first?.remoteControlID == "session_01Ab")
    }

    @Test func terminalSessionsHaveNoLink() throws {
        let desk = tempDir(), reg = tempDir()
        defer { try? FileManager.default.removeItem(at: desk); try? FileManager.default.removeItem(at: reg) }
        try write(["sessionId": "t", "entrypoint": "cli"], to: reg.appendingPathComponent("7.json"))
        try write(["sessionId": "bad id", "cliSessionId": "t"], to: desk.appendingPathComponent("local_x.json"))
        #expect(ConversationLink.url(for: info("t", pid: 7), desktopDir: desk.path, registryDir: reg.path) == nil)
    }
}
