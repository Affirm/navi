import Testing
import Foundation
import Darwin
@testable import NaviCore

@Suite("SessionGroup")
struct SessionGroupTests {
    private func makeInfo(
        pid: pid_t = 0,
        lastEventType: String = ""
    ) -> SessionInfo {
        var info = SessionInfo(
            id: "sid",
            projectName: "navi",
            shortSession: "navi-sho",
            cwd: "/tmp/navi",
            tty: "",
            sessionName: "",
            pid: pid
        )
        info.lastEventType = lastEventType
        return info
    }

    private func makeEvent(type: String = "notification", resolved: Bool = false) -> NaviEvent {
        NaviEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            type: type,
            title: "",
            body: "",
            description: "",
            sessionID: "sid",
            sessionName: "",
            pid: 0,
            cwd: "",
            tty: "",
            toolUseID: "",
            expires: nil,
            resolved: resolved
        )
    }

    // MARK: - hasPending

    @Test func hasPendingIsFalseForEmptyEvents() {
        let group = SessionGroup(id: "sid", info: makeInfo(), events: [])
        #expect(!group.hasPending)
    }

    @Test func hasPendingIsTrueWhenAnyPermissionUnresolved() {
        let group = SessionGroup(id: "sid", info: makeInfo(), events: [
            makeEvent(type: "notification"),
            makeEvent(type: "permission", resolved: false),
        ])
        #expect(group.hasPending)
    }

    @Test func hasPendingIsFalseWhenAllPermissionsResolved() {
        let group = SessionGroup(id: "sid", info: makeInfo(), events: [
            makeEvent(type: "permission", resolved: true),
            makeEvent(type: "stop"),
        ])
        #expect(!group.hasPending)
    }

    @Test func hasPendingIgnoresNonPermissionEvents() {
        let group = SessionGroup(id: "sid", info: makeInfo(), events: [
            makeEvent(type: "notification", resolved: false),
            makeEvent(type: "stop", resolved: false),
        ])
        #expect(!group.hasPending)
    }

    // MARK: - status

    @Test func statusIsNeedsAttentionWhenPending() {
        let group = SessionGroup(id: "sid", info: makeInfo(pid: getpid(), lastEventType: "working"), events: [
            makeEvent(type: "permission", resolved: false),
        ])
        #expect(group.status == .needsAttention)
    }

    @Test func statusIsNeedsAttentionEvenIfProcessDead() {
        let group = SessionGroup(id: "sid", info: makeInfo(pid: 0), events: [
            makeEvent(type: "permission", resolved: false),
        ])
        #expect(group.status == .needsAttention)
    }

    @Test func statusIsWorkingWhenAliveAndWorking() {
        let group = SessionGroup(id: "sid", info: makeInfo(pid: getpid(), lastEventType: "working"), events: [])
        #expect(group.status == .working)
    }

    @Test func statusIsWaitingForInputWhenAliveAndNotWorking() {
        let group = SessionGroup(id: "sid", info: makeInfo(pid: getpid(), lastEventType: "stop"), events: [])
        #expect(group.status == .waitingForInput)
    }

    @Test func statusIsWaitingForInputWhenAliveAndNoEventYet() {
        let group = SessionGroup(id: "sid", info: makeInfo(pid: getpid(), lastEventType: ""), events: [])
        #expect(group.status == .waitingForInput)
    }

    @Test func statusIsIdleWhenProcessDead() {
        let group = SessionGroup(id: "sid", info: makeInfo(pid: 0, lastEventType: "working"), events: [])
        // Dead process — lastEventType is ignored
        #expect(group.status == .idle)
    }
}
