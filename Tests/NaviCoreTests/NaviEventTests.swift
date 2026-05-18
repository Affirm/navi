import Testing
import Foundation
@testable import NaviCore

@Suite("NaviEvent")
struct NaviEventTests {
    private func makeEvent(
        type: String = "notification",
        sessionID: String = "session-abcdef0123456789",
        cwd: String = "",
        resolved: Bool = false
    ) -> NaviEvent {
        NaviEvent(
            id: "id-1",
            timestamp: Date(timeIntervalSince1970: 1_000),
            type: type,
            title: "",
            body: "",
            description: "",
            sessionID: sessionID,
            sessionName: "",
            pid: 0,
            cwd: cwd,
            tty: "",
            toolUseID: "",
            expires: nil,
            resolved: resolved,
            response: nil
        )
    }

    // MARK: - isPending

    @Test func pendingWhenPermissionAndUnresolved() {
        #expect(makeEvent(type: "permission", resolved: false).isPending)
    }

    @Test func notPendingWhenPermissionAndResolved() {
        #expect(!makeEvent(type: "permission", resolved: true).isPending)
    }

    @Test func notPendingWhenNotificationType() {
        #expect(!makeEvent(type: "notification", resolved: false).isPending)
        #expect(!makeEvent(type: "notification", resolved: true).isPending)
    }

    @Test func notPendingWhenStopType() {
        #expect(!makeEvent(type: "stop", resolved: false).isPending)
        #expect(!makeEvent(type: "stop", resolved: true).isPending)
    }

    @Test func notPendingForUnknownType() {
        #expect(!makeEvent(type: "anything-else", resolved: false).isPending)
    }

    // MARK: - projectName

    @Test func projectNameIsLastPathComponent() {
        #expect(makeEvent(cwd: "/Users/foo/projects/bar").projectName == "bar")
    }

    @Test func projectNameHandlesTrailingSlash() {
        #expect(makeEvent(cwd: "/Users/foo/projects/bar/").projectName == "bar")
    }

    @Test func projectNameIsEmptyForEmptyCwd() {
        #expect(makeEvent(cwd: "").projectName == "")
    }

    @Test func projectNameOfRootIsSlash() {
        #expect(makeEvent(cwd: "/").projectName == "/")
    }

    @Test func projectNameForRelativePath() {
        #expect(makeEvent(cwd: "foo/bar").projectName == "bar")
    }

    @Test func projectNameForSingleComponent() {
        #expect(makeEvent(cwd: "navi").projectName == "navi")
    }

    // MARK: - shortSession

    @Test func shortSessionTakesFirstEightChars() {
        #expect(makeEvent(sessionID: "abcdef0123456789").shortSession == "abcdef01")
    }

    @Test func shortSessionForShorterIDReturnsWholeString() {
        #expect(makeEvent(sessionID: "abc").shortSession == "abc")
    }

    @Test func shortSessionForExactEightChars() {
        #expect(makeEvent(sessionID: "12345678").shortSession == "12345678")
    }

    @Test func shortSessionForEmptyIDIsEmpty() {
        #expect(makeEvent(sessionID: "").shortSession == "")
    }
}
