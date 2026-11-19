import Testing
import Foundation
@testable import NaviCore

private let eid = "1700000000-" + String(repeating: "ab", count: 16)

/// Records everything the bridge delivers. Thread-safe.
final class RecordingSink: RemoteEventSink {
    private let lock = NSLock()
    private(set) var events: [(String, [String: Any])] = []
    private(set) var resolves: [(String, [String: Any])] = []
    private(set) var working: [(String, String)] = []
    private(set) var heartbeats: [(String, [DiscoveredSession], Set<String>?)] = []
    private(set) var liveness: [(String, OriginLiveness)] = []
    private(set) var removed: [String] = []

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    func ingestRemoteEvent(_ dict: [String: Any], origin: String) { locked { events.append((origin, dict)) } }
    func ingestRemoteResolve(_ dict: [String: Any], origin: String) { locked { resolves.append((origin, dict)) } }
    func ingestRemoteWorking(sessionID: String, origin: String) { locked { working.append((origin, sessionID)) } }
    func applyRemoteHeartbeat(origin: String, sessions: [DiscoveredSession], live: Set<String>?) {
        locked { heartbeats.append((origin, sessions, live)) }
    }
    func setLiveness(origin: String, _ state: OriginLiveness) { locked { liveness.append((origin, state)) } }
    func removeOrigin(_ origin: String) { locked { removed.append(origin) } }

    var eventCount: Int { locked { events.count } }
    var heartbeatCount: Int { locked { heartbeats.count } }
    var disconnects: Int { locked { liveness.filter { $0.1 == .disconnected }.count } }
}

/// Poll until `condition` holds or the timeout elapses.
private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func eventuallyOnMain(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("navi-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("RemoteMessage")
struct RemoteMessageTests {
    private func parse(_ s: String) -> RemoteMessage? { RemoteMessage.parse(Data(s.utf8)) }

    @Test func parsesEvent() {
        guard case let .event(d)? = parse(#"{"kind":"event","event":{"id":"x","type":"stop"}}"#) else {
            Issue.record("not an event"); return
        }
        #expect(d["type"] as? String == "stop")
    }

    @Test func parsesHeartbeatAndUsesLiveAsAuthority() {
        let line = #"{"kind":"heartbeat","live":["a"],"sessions":[{"sessionId":"a","pid":5,"cwd":"/w"},{"sessionId":"b","pid":6}],"user":"u","host":"h"}"#
        guard case let .heartbeat(live, sessions, user, host)? = parse(line) else {
            Issue.record("not a heartbeat"); return
        }
        #expect(live == ["a"])
        #expect(user == "u" && host == "h")
        #expect(sessions.first { $0.sessionID == "a" }?.alive == true)
        #expect(sessions.first { $0.sessionID == "b" }?.alive == false)
    }

    @Test func heartbeatWithoutLiveIsUnknown() {
        guard case let .heartbeat(live, _, _, _)? = parse(#"{"kind":"heartbeat"}"#) else {
            Issue.record("not a heartbeat"); return
        }
        #expect(live == nil)
    }

    @Test func heartbeatDropsInvalidSessionIDs() {
        guard case let .heartbeat(live, sessions, _, _)? =
                parse(#"{"kind":"heartbeat","live":["ok","../x"],"sessions":[{"sessionId":"../x","pid":1}]}"#) else {
            Issue.record("not a heartbeat"); return
        }
        #expect(live == ["ok"])
        #expect(sessions.isEmpty)
    }

    @Test func rejectsGarbageAndUnknownKinds() {
        #expect(parse("not json") == nil)
        #expect(parse(#"{"kind":"nope"}"#) == nil)
        #expect(parse(#"{"kind":"event","event":"str"}"#) == nil)
        #expect(parse(#"{"kind":"working","session_id":"a/b"}"#) == nil)
        #expect(parse("[1,2]") == nil)
    }

    @Test func responseLineFormat() throws {
        let data = try #require(RemoteMessage.responseLine(id: eid, decision: "approve"))
        #expect(data.last == 0x0A)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(obj == ["kind": "response", "id": eid, "decision": "approve"])
    }

    @Test func responseLineRejectsBadInput() {
        #expect(RemoteMessage.responseLine(id: "../etc", decision: "approve") == nil)
        #expect(RemoteMessage.responseLine(id: eid, decision: "allow") == nil)
        #expect(RemoteMessage.responseLine(id: eid.uppercased(), decision: "deny") == nil)
    }
}

@Suite("RemoteHosts")
struct RemoteHostsTests {
    @Test func aliasValidation() {
        for ok in ["devbox", "gpu-01.example.com", "me@devbox", "10.0.0.5", "user_x@host.lan"] {
            #expect(RemoteHostConfig.isValidAlias(ok), "\(ok)")
        }
        for bad in ["", "-oProxyCommand=evil", "host;rm -rf", "a b", "x@y@z", "@host", "host@",
                    "$(id)", "host\nother", String(repeating: "a", count: 300)] {
            #expect(!RemoteHostConfig.isValidAlias(bad), "\(bad)")
        }
    }

    @Test func remoteCommandRoundTripsSource() throws {
        let cmd = RelayCommand.remoteShellCommand(features: ["auto-dismiss", "terminal-focus", "session-names"],
                                                  source: "print('hi')\n")
        #expect(cmd.hasPrefix("python3 -c 'import base64;exec(base64.b64decode(\""))
        #expect(cmd.hasSuffix(" --features auto-dismiss,session-names"))
        let b64 = try #require(cmd.split(separator: "\"").dropFirst().first)
        let decoded = try #require(Data(base64Encoded: String(b64)))
        #expect(String(decoding: decoded, as: UTF8.self) == "print('hi')\n")
        // Nothing the remote shell could interpret outside the quotes.
        let unquoted = cmd.replacingOccurrences(of: #"'[^']*'"#, with: "", options: .regularExpression)
        #expect(unquoted.range(of: #"[^A-Za-z0-9 ,-]"#, options: .regularExpression) == nil)
    }

    @Test func sshArgumentsEndOptionsBeforeAlias() {
        let args = RelayCommand.sshArguments(alias: "devbox", remoteCommand: "cmd")
        #expect(args.contains("BatchMode=yes"))
        let dd = args.firstIndex(of: "--")!
        #expect(args[dd + 1] == "devbox")
        #expect(args.last == "cmd")
    }

    @Test func errorHints() {
        #expect(RemoteErrorHint.describe(alias: "d", exitCode: 255, stderr: "Host key verification failed.\n")
            .contains("Run `ssh d` once in Terminal"))
        #expect(RemoteErrorHint.describe(alias: "d", exitCode: 255, stderr: "me@d: Permission denied (publickey).")
            .contains("ssh d"))
        #expect(RemoteErrorHint.describe(alias: "d", exitCode: 255, stderr: "ssh: Could not resolve hostname d")
            .contains("Unknown host"))
        #expect(RemoteErrorHint.describe(alias: "d", exitCode: 127, stderr: "bash: python3: command not found")
            .contains("python3"))
        #expect(RemoteErrorHint.describe(alias: "d", exitCode: 1, stderr: "") .contains("exit 1"))
    }

    @Test func backoffDoublesAndCaps() {
        var b = Backoff()
        let delays = (0..<9).map { _ in b.next() }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        b.reset()
        #expect(b.next() == 1)
    }

    @Test func settingsRoundTripDropsInvalidAndDuplicates() throws {
        let suite = "navi-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RemoteHostsSettings.loadHosts(from: defaults).isEmpty)
        RemoteHostsSettings.saveHosts([
            RemoteHostConfig(alias: "a"), RemoteHostConfig(alias: "-bad"),
            RemoteHostConfig(alias: "b", enabled: false), RemoteHostConfig(alias: "a"),
        ], to: defaults)
        #expect(RemoteHostsSettings.loadHosts(from: defaults) ==
                [RemoteHostConfig(alias: "a"), RemoteHostConfig(alias: "b", enabled: false)])
    }

    @Test func flagConfigShape() {
        let cfg = RemoteHostsSettings.flagConfig(for: [RemoteHostConfig(alias: "a", enabled: false)])
        let hosts = cfg["hosts"] as? [[String: Any]]
        #expect(hosts?.first?["alias"] as? String == "a")
        #expect(hosts?.first?["enabled"] as? Bool == false)
        #expect(JSONSerialization.isValidJSONObject(cfg))
    }

    @Test func embeddedRelayMatchesHooksRelay() throws {
        let file = try String(contentsOf: repoRoot.appendingPathComponent("hooks/relay.py"), encoding: .utf8)
        #expect(RelaySource.python + "\n" == file,
                "Sources/NaviCore/RelaySource.generated.swift is stale: run scripts/embed-relay.sh")
    }
}

@Suite("RemoteBridge", .serialized)
struct RemoteBridgeTests {
    @Test func cannedJSONLReachesSinkAndResponsesAreWritten() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let received = dir.appendingPathComponent("stdin.txt").path
        let script = """
        printf '%s\\n' '{"kind":"hello","version":1,"user":"u","host":"h"}' \
          '{"kind":"heartbeat","live":["s1"],"sessions":[{"sessionId":"s1","pid":9}],"user":"u","host":"h"}' \
          '{"kind":"event","event":{"id":"\(eid)","type":"permission","session_id":"s1"}}' \
          '{"kind":"resolve","resolve":{"tool_use_id":"t1"}}' \
          '{"kind":"working","session_id":"s1"}' \
          'garbage line'
        exec cat > "$1"
        """
        let bridge = RemoteBridge(transport: CommandTransport(executable: "/bin/sh",
                                                              arguments: ["-c", script, "sh", received]))
        let sink = RecordingSink()
        bridge.attach(sink: sink)
        bridge.configure(hosts: [RemoteHostConfig(alias: "devbox")], features: [])

        #expect(await eventually { sink.eventCount == 1 && sink.working.count == 1 })
        #expect(sink.events.first?.0 == "devbox")
        #expect(sink.resolves.first?.1["tool_use_id"] as? String == "t1")
        #expect(sink.heartbeats.first?.2 == ["s1"])
        #expect(await eventually { bridge.stateSnapshot("devbox")?.status == .connected })
        #expect(bridge.stateSnapshot("devbox")?.remoteUser == "u")

        #expect(bridge.respond(origin: "devbox", id: eid, decision: "deny"))
        #expect(!bridge.respond(origin: "devbox", id: "bad", decision: "deny"))
        #expect(!bridge.respond(origin: "otherhost", id: eid, decision: "deny"))
        #expect(await eventually {
            (try? String(contentsOfFile: received, encoding: .utf8)) ==
                #"{"decision":"deny","id":"\#(eid)","kind":"response"}"# + "\n"
        })

        bridge.stopAll()
        #expect(await eventually { sink.removed == ["devbox"] })
    }

    @Test func disconnectFlagsHostAndReconnectsWithBackoff() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("launches").path
        let script = #"echo x >> "$1"; echo 'me@devbox: Permission denied (publickey).' >&2; exit 255"#
        let bridge = RemoteBridge(
            transport: CommandTransport(executable: "/bin/sh", arguments: ["-c", script, "sh", counter]),
            backoff: Backoff(base: 0.05, cap: 0.2))
        let sink = RecordingSink()
        bridge.attach(sink: sink)
        bridge.configure(hosts: [RemoteHostConfig(alias: "devbox")], features: [])

        #expect(await eventually { sink.disconnects >= 2 })
        let launches = (try? String(contentsOfFile: counter, encoding: .utf8))?.split(separator: "\n").count ?? 0
        #expect(launches >= 2)
        let state = bridge.stateSnapshot("devbox")
        #expect(state?.status == .disconnected)
        #expect(state?.lastError?.contains("ssh devbox") == true)
        #expect(state?.nextRetry != nil)
        #expect(!bridge.respond(origin: "devbox", id: eid, decision: "approve"))
        bridge.stopAll()
    }

    @Test func disabledAndInvalidHostsAreNeverStarted() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("launches").path
        let bridge = RemoteBridge(transport: CommandTransport(
            executable: "/bin/sh", arguments: ["-c", #"echo x >> "$1"; exec cat"#, "sh", counter]))
        bridge.attach(sink: RecordingSink())
        bridge.configure(hosts: [RemoteHostConfig(alias: "off", enabled: false),
                                 RemoteHostConfig(alias: "-oProxyCommand=x")], features: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!FileManager.default.fileExists(atPath: counter))
        bridge.stopAll()
    }

    /// End to end against the real relay.py with a private --root.
    @Test func realRelayEventAndResponse() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("navi").path
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionFile = #"{"sessionId":"live1","pid":\#(ProcessInfo.processInfo.processIdentifier),"cwd":"/w/p"}"#
        try sessionFile.write(to: sessions.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)

        let bridge = RemoteBridge(transport: LocalRelayTransport(
            relayPath: repoRoot.appendingPathComponent("hooks/relay.py").path,
            root: root, sessionsDir: sessions.path, heartbeat: 0.2))
        let sink = RecordingSink()
        bridge.attach(sink: sink)
        bridge.configure(hosts: [RemoteHostConfig(alias: "local-relay")], features: ["auto-dismiss"])

        #expect(await eventually { sink.heartbeatCount > 0 })
        #expect(sink.heartbeats.first?.2 == ["live1"])
        #expect(FileManager.default.fileExists(atPath: "\(root)/features/auto-dismiss"))

        let event = #"{"id":"\#(eid)","type":"permission","session_id":"live1","timestamp":1}"#
        try event.write(toFile: "\(root)/events/.tmp", atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(atPath: "\(root)/events/.tmp", toPath: "\(root)/events/\(eid).json")
        #expect(await eventually { sink.eventCount == 1 })
        #expect(sink.events.first?.1["id"] as? String == eid)

        #expect(bridge.respond(origin: "local-relay", id: eid, decision: "approve"))
        #expect(await eventually {
            (try? String(contentsOfFile: "\(root)/responses/\(eid)", encoding: .utf8)) == "approve"
        })

        bridge.stopAll()
        // stdin closed -> relay exits and removes its heartbeat file.
        #expect(await eventually { !FileManager.default.fileExists(atPath: "\(root)/relay.alive") })
    }
}

@Suite("EventMonitor remote ingestion", .serialized)
struct EventMonitorRemoteTests {
    @Test func remoteEventCreatesOriginScopedSessionAndRoutesResponse() async throws {
        final class FakeResponder: RemoteResponder {
            var calls: [(String, String, String)] = []
            func respond(origin: String, id: String, decision: String) -> Bool {
                calls.append((origin, id, decision)); return true
            }
        }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let monitor = EventMonitor(stateDir: dir.path, watch: false)
        let responder = FakeResponder()
        monitor.remoteResponder = responder
        monitor.applyRemoteHeartbeat(
            origin: "devbox",
            sessions: [DiscoveredSession(sessionID: "rs1", pid: 4242, alive: true, cwd: "/srv/app")],
            live: ["rs1"])
        monitor.ingestRemoteEvent(["id": eid, "type": "permission", "session_id": "rs1",
                                   "tty": "/dev/ttys001", "cwd": "/srv/app"], origin: "devbox")
        // Same id again must be ignored; bad type / bad session id rejected.
        monitor.ingestRemoteEvent(["id": eid, "type": "permission", "session_id": "rs1"], origin: "devbox")
        monitor.ingestRemoteEvent(["id": "x1", "type": "exec", "session_id": "rs1"], origin: "devbox")
        monitor.ingestRemoteEvent(["id": "x2", "type": "stop", "session_id": "../x"], origin: "devbox")

        let key = SessionKey(origin: "devbox", sessionID: "rs1")
        #expect(await eventuallyOnMain { monitor.sessions[key] != nil && monitor.events.count == 1 })
        await MainActor.run {
            let e = monitor.events[0]
            #expect(e.origin == "devbox")
            #expect(e.tty.isEmpty)
            #expect(monitor.sessions[key]?.origin == "devbox")
            monitor.respond(to: eid, with: "approve")
        }
        #expect(responder.calls.count == 1)
        #expect(responder.calls.first?.0 == "devbox")
        #expect(await eventuallyOnMain { monitor.events.first?.resolved == true })

        monitor.removeOrigin("devbox")
        #expect(await eventuallyOnMain { monitor.sessions[key] == nil && monitor.events.isEmpty })
    }
}
