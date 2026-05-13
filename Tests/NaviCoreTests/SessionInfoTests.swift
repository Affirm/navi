import Testing
import Foundation
import Darwin
@testable import NaviCore

/// `displayName` reads `UserDefaults.standard` global state, so these tests
/// must not run in parallel with each other.
@Suite("SessionInfo", .serialized)
struct SessionInfoTests {
    private static let sessionNamesKey = "NaviExp.SessionNames"

    private func makeInfo(
        sessionName: String = "",
        projectName: String = "my-project",
        pid: pid_t = 0
    ) -> SessionInfo {
        SessionInfo(
            id: "session-id",
            projectName: projectName,
            shortSession: "session-",
            cwd: "/tmp/\(projectName)",
            tty: "",
            sessionName: sessionName,
            pid: pid
        )
    }

    /// Save the existing default, run the body with `value`, then restore.
    private func withSessionNamesFlag(_ value: Bool, _ body: () -> Void) {
        let original = UserDefaults.standard.object(forKey: Self.sessionNamesKey)
        defer {
            if let original = original {
                UserDefaults.standard.set(original, forKey: Self.sessionNamesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.sessionNamesKey)
            }
        }
        UserDefaults.standard.set(value, forKey: Self.sessionNamesKey)
        body()
    }

    @Test func displayNameFallsBackToProjectWhenFlagOff() {
        withSessionNamesFlag(false) {
            let info = makeInfo(sessionName: "Custom Name", projectName: "navi")
            #expect(info.displayName == "navi")
        }
    }

    @Test func displayNameFallsBackToProjectWhenSessionNameEmpty() {
        withSessionNamesFlag(true) {
            let info = makeInfo(sessionName: "", projectName: "navi")
            #expect(info.displayName == "navi")
        }
    }

    @Test func displayNameUsesSessionNameWhenFlagOnAndNameSet() {
        withSessionNamesFlag(true) {
            let info = makeInfo(sessionName: "Custom Name", projectName: "navi")
            #expect(info.displayName == "Custom Name")
        }
    }

    @Test func displayNameFallsBackToProjectWhenFlagOffEvenWithName() {
        withSessionNamesFlag(false) {
            let info = makeInfo(sessionName: "X", projectName: "Y")
            #expect(info.displayName == "Y")
        }
    }

    @Test func isAliveIsFalseForZeroPid() {
        #expect(!makeInfo(pid: 0).isAlive)
    }

    @Test func isAliveIsFalseForNegativePid() {
        #expect(!makeInfo(pid: -1).isAlive)
    }

    @Test func isAliveIsTrueForCurrentProcess() {
        #expect(makeInfo(pid: getpid()).isAlive)
    }

    @Test func isAliveIsFalseForLikelyDeadPid() {
        // PIDs are 32-bit; very high numbers are extremely unlikely to be in
        // use. kill(pid, 0) returns -1 with errno=ESRCH for such PIDs.
        #expect(!makeInfo(pid: 999_999).isAlive)
    }
}
