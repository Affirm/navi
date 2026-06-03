import Testing
import Foundation
import Darwin
@testable import NaviCore

@Suite("SessionGroup")
struct SessionGroupTests {
    private func makeInfo(
        pid: pid_t = 0,
        lastEventType: String = "",
        lastActivity: Date = Date(),
        claudeStatus: String = "",
        statusUpdatedAt: Date? = nil
    ) -> SessionInfo {
        var info = SessionInfo(
            id: "sid",
            projectName: "navi",
            shortSession: "navi-sho",
            cwd: "/tmp/navi",
            tty: "",
            sessionName: "",
            pid: pid,
            lastActivity: lastActivity,
            claudeStatus: claudeStatus,
            statusUpdatedAt: statusUpdatedAt
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

    // MARK: - canonical status reconcile

    @Test func canonicalIdleNewerThanHookHealsStuckWorking() {
        // Missed Stop hook: hook still says "working", but the canonical file
        // updated more recently to "idle" — canonical wins.
        let hookAt = Date()
        let info = makeInfo(
            pid: getpid(), lastEventType: "working", lastActivity: hookAt,
            claudeStatus: "idle", statusUpdatedAt: hookAt.addingTimeInterval(5))
        #expect(SessionGroup(id: "sid", info: info, events: []).status == .waitingForInput)
    }

    @Test func canonicalBusyNewerThanHookHealsStuckIdle() {
        // Missed UserPromptSubmit hook: hook says "stop", canonical says "busy"
        // and is newer — canonical wins.
        let hookAt = Date()
        let info = makeInfo(
            pid: getpid(), lastEventType: "stop", lastActivity: hookAt,
            claudeStatus: "busy", statusUpdatedAt: hookAt.addingTimeInterval(5))
        #expect(SessionGroup(id: "sid", info: info, events: []).status == .working)
    }

    @Test func freshHookWinsOverOlderCanonical() {
        // A just-fired hook (newer than the canonical write) keeps Navi instant.
        let canonicalAt = Date()
        let info = makeInfo(
            pid: getpid(), lastEventType: "working", lastActivity: canonicalAt.addingTimeInterval(5),
            claudeStatus: "idle", statusUpdatedAt: canonicalAt)
        #expect(SessionGroup(id: "sid", info: info, events: []).status == .working)
    }

    @Test func missingCanonicalTimestampFallsBackToHook() {
        // Canonical status present but no updatedAt — can't reconcile, use hook.
        let info = makeInfo(
            pid: getpid(), lastEventType: "working",
            claudeStatus: "idle", statusUpdatedAt: nil)
        #expect(SessionGroup(id: "sid", info: info, events: []).status == .working)
    }

    @Test func canonicalWaitingIsDeferredToHookPath() {
        // "waiting" is intentionally not reconciled here (remote-approval
        // handling lands with the tmux work) — the hook view stands.
        let hookAt = Date()
        let info = makeInfo(
            pid: getpid(), lastEventType: "working", lastActivity: hookAt,
            claudeStatus: "waiting", statusUpdatedAt: hookAt.addingTimeInterval(5))
        #expect(SessionGroup(id: "sid", info: info, events: []).status == .working)
    }

    @Test func pendingPermissionWinsOverCanonicalStatus() {
        let hookAt = Date()
        let info = makeInfo(
            pid: getpid(), lastEventType: "working", lastActivity: hookAt,
            claudeStatus: "busy", statusUpdatedAt: hookAt.addingTimeInterval(5))
        let group = SessionGroup(id: "sid", info: info, events: [
            makeEvent(type: "permission", resolved: false),
        ])
        #expect(group.status == .needsAttention)
    }
}
