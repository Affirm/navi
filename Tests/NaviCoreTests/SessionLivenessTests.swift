import Testing
import Foundation
@testable import NaviCore

@Suite("SessionLiveness")
struct SessionLivenessTests {
    private func info(_ sid: String, origin: String = "", pid: pid_t = 100,
                      disconnected: Bool = false) -> SessionInfo {
        SessionInfo(id: sid, projectName: "p", shortSession: String(sid.prefix(8)),
                    cwd: "/w/p", tty: "", sessionName: "", pid: pid,
                    origin: origin, isDisconnected: disconnected)
    }

    private func table(_ infos: [SessionInfo]) -> [SessionKey: SessionInfo] {
        Dictionary(uniqueKeysWithValues: infos.map { ($0.key, $0) })
    }

    // MARK: - SessionKey

    @Test func keyIdKeepsBareSessionIDForLocal() {
        #expect(SessionKey(sessionID: "abc").id == "abc")
        #expect(SessionKey(origin: "devbox", sessionID: "abc").id == "devbox/abc")
    }

    @Test func sameSessionIDOnDifferentOriginsAreDistinct() {
        let t = table([info("abc"), info("abc", origin: "devbox")])
        #expect(t.count == 2)
    }

    // MARK: - prune

    @Test func localDeadSessionIsPruned() {
        var t = table([info("alive"), info("dead")])
        let r = SessionReconciler.prune(&t, liveness: ["": .live(["alive"])])
        #expect(r.pruned == [SessionKey(sessionID: "dead")])
        #expect(r.changed)
        #expect(t.keys.map(\.sessionID) == ["alive"])
    }

    @Test func localUnknownLivenessSkipsPruning() {
        var t = table([info("a"), info("b")])
        let r = SessionReconciler.prune(&t, liveness: ["": .unknown])
        #expect(r.pruned.isEmpty)
        #expect(!r.changed)
        #expect(t.count == 2)
    }

    @Test func remoteSessionMissingFromHeartbeatIsPruned() {
        var t = table([info("r1", origin: "devbox"), info("r2", origin: "devbox")])
        let r = SessionReconciler.prune(&t, liveness: ["devbox": .live(["r1"])])
        #expect(r.pruned == [SessionKey(origin: "devbox", sessionID: "r2")])
        #expect(t.count == 1)
    }

    @Test func remoteHostDisconnectedKeepsAndFlagsSessions() {
        var t = table([info("r1", origin: "devbox"), info("r2", origin: "devbox")])
        let r = SessionReconciler.prune(&t, liveness: ["devbox": .disconnected])
        #expect(r.pruned.isEmpty)
        #expect(r.changed)
        #expect(t.count == 2)
        #expect(t.values.allSatisfy { $0.isDisconnected })
    }

    @Test func reconnectClearsDisconnectedFlag() {
        var t = table([info("r1", origin: "devbox", disconnected: true)])
        let r = SessionReconciler.prune(&t, liveness: ["devbox": .live(["r1"])])
        #expect(r.changed)
        #expect(t[SessionKey(origin: "devbox", sessionID: "r1")]?.isDisconnected == false)
    }

    @Test func alreadyDisconnectedIsNotAChange() {
        var t = table([info("r1", origin: "devbox", disconnected: true)])
        let r = SessionReconciler.prune(&t, liveness: ["devbox": .disconnected])
        #expect(!r.changed)
    }

    @Test func originsArePrunedIndependently() {
        // Same session id on both origins; only the local one is dead.
        var t = table([info("abc"), info("abc", origin: "devbox")])
        let r = SessionReconciler.prune(&t, liveness: ["": .live([]), "devbox": .live(["abc"])])
        #expect(r.pruned == [SessionKey(sessionID: "abc")])
        #expect(t.keys.first == SessionKey(origin: "devbox", sessionID: "abc"))
    }

    @Test func originWithoutLivenessEntryIsLeftAlone() {
        // A remote origin that has not reported yet must not be pruned by
        // the local scan.
        var t = table([info("l"), info("r", origin: "devbox")])
        let r = SessionReconciler.prune(&t, liveness: ["": .live(["l"])])
        #expect(r.pruned.isEmpty)
        #expect(t.count == 2)
    }

    // MARK: - merge

    @Test func mergeAddsOnlyLiveNewSessions() {
        var t: [SessionKey: SessionInfo] = [:]
        let added = SessionReconciler.merge([
            DiscoveredSession(sessionID: "live", pid: 10, alive: true, cwd: "/w/proj", name: "n"),
            DiscoveredSession(sessionID: "dead", pid: 11, alive: false),
            DiscoveredSession(sessionID: "nopid", pid: nil, alive: false),
        ], origin: "devbox", into: &t)
        #expect(added == [SessionKey(origin: "devbox", sessionID: "live")])
        let s = t[SessionKey(origin: "devbox", sessionID: "live")]
        #expect(s?.origin == "devbox")
        #expect(s?.projectName == "proj")
        #expect(s?.sessionName == "n")
        #expect(s?.pid == 10)
    }

    @Test func mergeRefreshesStatusAndPidForTracked() {
        var t = table([info("a", pid: 10)])
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let added = SessionReconciler.merge([
            DiscoveredSession(sessionID: "a", pid: 20, alive: true, claudeStatus: "busy", statusUpdatedAt: at),
        ], origin: "", into: &t)
        #expect(added.isEmpty)
        let s = t[SessionKey(sessionID: "a")]!
        #expect(s.pid == 20)
        #expect(s.claudeStatus == "busy")
        #expect(s.statusUpdatedAt == at)
    }

    @Test func mergeKeepsPidWhenNewProcessIsDead() {
        var t = table([info("a", pid: 10)])
        SessionReconciler.merge([DiscoveredSession(sessionID: "a", pid: 20, alive: false)],
                                origin: "", into: &t)
        #expect(t[SessionKey(sessionID: "a")]?.pid == 10)
    }

    @Test func mergeUsesTtyLookupForNewSessions() {
        var t: [SessionKey: SessionInfo] = [:]
        SessionReconciler.merge([DiscoveredSession(sessionID: "a", pid: 42, alive: true)],
                                origin: "", into: &t, ttyLookup: { "/dev/ttys\($0)" })
        #expect(t[SessionKey(sessionID: "a")]?.tty == "/dev/ttys42")
    }

    // MARK: - DiscoveredSession.parse

    @Test func parseReadsRegistryFields() {
        let d = DiscoveredSession.parse([
            "sessionId": "s1", "pid": 7, "cwd": "/x", "name": "nm",
            "status": "idle", "updatedAt": 1_700_000_000_000,
        ], isAlive: { $0 == 7 })
        #expect(d == DiscoveredSession(sessionID: "s1", pid: 7, alive: true, cwd: "/x", name: "nm",
                                       claudeStatus: "idle",
                                       statusUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    @Test func parseRejectsMissingSessionID() {
        #expect(DiscoveredSession.parse(["pid": 1], isAlive: { _ in true }) == nil)
    }

    @Test func parseWithoutPidIsNotAlive() {
        let d = DiscoveredSession.parse(["sessionId": "s"], isAlive: { _ in true })
        #expect(d?.alive == false)
    }

    // MARK: - remote liveness / status

    @Test func remoteSessionIsAliveUnlessDisconnected() {
        // pid 1 (launchd) is alive locally, but a remote pid must never be
        // probed with kill(): only the disconnected flag matters.
        #expect(info("r", origin: "devbox", pid: 999_999).isAlive)
        #expect(!info("r", origin: "devbox", pid: 1, disconnected: true).isAlive)
    }

    @Test func disconnectedRemoteGroupShowsDisconnected() {
        let g = SessionGroup(id: "devbox/r", info: info("r", origin: "devbox", disconnected: true), events: [])
        #expect(g.status == .disconnected)
        #expect(g.status.label == "Disconnected")
    }

    @Test func localSessionIgnoresDisconnectedFlagForStatus() {
        let g = SessionGroup(id: "l", info: info("l", pid: 0, disconnected: true), events: [])
        #expect(g.status == .idle)
    }

    @Test func makeEventCarriesOrigin() {
        let e = EventMonitor.makeEvent(from: ["id": "1-ab", "type": "stop", "session_id": "s"],
                                       fallbackID: "x", origin: "devbox")
        #expect(e.origin == "devbox")
        #expect(e.sessionKey == SessionKey(origin: "devbox", sessionID: "s"))
        #expect(e.id == "1-ab")
        let local = EventMonitor.makeEvent(from: [:], fallbackID: "fb", origin: "")
        #expect(local.id == "fb")
        #expect(local.type == "notification")
        #expect(local.sessionKey.isLocal)
    }
}

@Suite("Dismissed sessions")
struct DismissedSessionTests {
    @Test func mergeSkipsDismissed() {
        var t: [SessionKey: SessionInfo] = [:]
        let added = SessionReconciler.merge(
            [DiscoveredSession(sessionID: "a", pid: 1, alive: true),
             DiscoveredSession(sessionID: "b", pid: 2, alive: true)],
            origin: "devbox", into: &t, skip: [SessionKey(origin: "devbox", sessionID: "a")])
        #expect(added == [SessionKey(origin: "devbox", sessionID: "b")])
    }

    @Test func pruneDismissedDropsEndedSessionsOnly() {
        let a = SessionKey(origin: "devbox", sessionID: "a")
        let b = SessionKey(origin: "devbox", sessionID: "b")
        let l = SessionKey(sessionID: "l")
        let kept = SessionReconciler.pruneDismissed([a, b, l], liveness: ["devbox": .live(["a"]), "": .unknown])
        #expect(kept == [a, l])
        #expect(SessionReconciler.pruneDismissed([a], liveness: ["devbox": .disconnected]) == [a])
    }
}

@Suite("Session titles")
struct SessionTitleTests {
    @Test func heartbeatTitleParsedAndMergedAndShown() {
        let d = DiscoveredSession.parse(["sessionId": "s", "pid": 1, "cwd": "/w/myapp-1d", "title": "Fix login"],
                                        isAlive: { _ in true })
        #expect(d?.title == "Fix login")
        var t: [SessionKey: SessionInfo] = [:]
        SessionReconciler.merge([d!], origin: "ops", into: &t)
        let key = SessionKey(origin: "ops", sessionID: "s")
        #expect(t[key]?.displayName(useSessionName: true) == "Fix login")
        #expect(t[key]?.displayName(useSessionName: false) == "myapp-1d")

        // Title updates on later heartbeats; an empty title doesn't erase it.
        SessionReconciler.merge([DiscoveredSession(sessionID: "s", pid: 1, alive: true, title: "Auth work")],
                                origin: "ops", into: &t)
        #expect(t[key]?.title == "Auth work")
        SessionReconciler.merge([DiscoveredSession(sessionID: "s", pid: 1, alive: true)], origin: "ops", into: &t)
        #expect(t[key]?.title == "Auth work")

        // An explicit session name still wins over the title.
        t[key]!.sessionName = "Renamed"
        #expect(t[key]?.displayName(useSessionName: true) == "Renamed")
    }

    @Test func remoteMessageHeartbeatKeepsTitle() {
        let line = #"{"kind":"heartbeat","live":["s"],"sessions":[{"sessionId":"s","pid":2,"title":"Hello"}]}"#
        guard case let .heartbeat(_, sessions, _, _)? = RemoteMessage.parse(Data(line.utf8)) else {
            Issue.record("not a heartbeat"); return
        }
        #expect(sessions.first?.title == "Hello")
    }
}
