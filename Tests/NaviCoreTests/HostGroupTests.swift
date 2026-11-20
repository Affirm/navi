import Testing
import Foundation
@testable import NaviCore

@Suite("HostGroup")
struct HostGroupTests {
    private func session(_ sid: String, origin: String = "", at t: TimeInterval,
                         pending: Bool = false, disconnected: Bool = false) -> SessionGroup {
        let info = SessionInfo(id: sid, projectName: "p", shortSession: sid, cwd: "/p", tty: "",
                               sessionName: "", pid: 0, lastActivity: Date(timeIntervalSince1970: t),
                               origin: origin, isDisconnected: disconnected)
        let events = pending ? [NaviEvent(id: "e-\(sid)", timestamp: Date(timeIntervalSince1970: t),
                                          type: "permission", title: "", body: "", description: "",
                                          sessionID: sid, sessionName: "", pid: 0, cwd: "", tty: "",
                                          toolUseID: "", expires: nil, origin: origin)] : []
        return SessionGroup(id: info.key.id, info: info, events: events)
    }

    @Test func groupWithLatestActivityComesFirst() {
        let hosts = HostGroup.make(from: [
            session("l1", at: 100),
            session("a1", origin: "alpha", at: 50),
            session("b1", origin: "beta", at: 300),
            session("a2", origin: "alpha", at: 200),
        ])
        #expect(hosts.map(\.title) == ["beta", "alpha", "This Mac"])
        #expect(hosts[1].sessions.map(\.info.id) == ["a2", "a1"])
    }

    @Test func pendingSessionsLeadWithinAGroup() {
        let hosts = HostGroup.make(from: [
            session("new", origin: "h", at: 500),
            session("ask", origin: "h", at: 10, pending: true),
        ])
        #expect(hosts[0].sessions.map(\.info.id) == ["ask", "new"])
        #expect(hosts[0].pendingCount == 1)
        #expect(hosts[0].collapsedSessions.map(\.info.id) == ["ask"])
    }

    @Test func groupingOnlyWhenRemoteSessionsExist() {
        #expect(!HostGroup.shouldGroup([session("l", at: 1)]))
        #expect(HostGroup.shouldGroup([session("l", at: 1), session("r", origin: "h", at: 1)]))
    }

    @Test func disconnectedAndIdentity() {
        let hosts = HostGroup.make(from: [session("r", origin: "h", at: 1, disconnected: true), session("l", at: 0)])
        #expect(hosts[0].isDisconnected)
        #expect(hosts[0].id == "host:h")
        #expect(!hosts[1].isDisconnected)
        #expect(hosts[1].id == "local")
    }
}
