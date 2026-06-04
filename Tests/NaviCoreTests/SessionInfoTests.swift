import Testing
import Foundation
import Darwin
@testable import NaviCore

@Suite("SessionInfo")
struct SessionInfoTests {
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

    @Test func displayNameFallsBackToProjectWhenFlagOff() {
        let info = makeInfo(sessionName: "Custom Name", projectName: "navi")
        #expect(info.displayName(useSessionName: false) == "navi")
    }

    @Test func displayNameFallsBackToProjectWhenSessionNameEmpty() {
        let info = makeInfo(sessionName: "", projectName: "navi")
        #expect(info.displayName(useSessionName: true) == "navi")
    }

    @Test func displayNameUsesSessionNameWhenFlagOnAndNameSet() {
        let info = makeInfo(sessionName: "Custom Name", projectName: "navi")
        #expect(info.displayName(useSessionName: true) == "Custom Name")
    }

    @Test func displayNameFallsBackToProjectWhenFlagOffEvenWithName() {
        let info = makeInfo(sessionName: "X", projectName: "Y")
        #expect(info.displayName(useSessionName: false) == "Y")
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

    @Test func isAliveAmongIsTrueWhenIdInLiveSet() {
        // makeInfo uses id "session-id". A live process holds it regardless of PID.
        #expect(makeInfo(pid: 0).isAlive(among: ["session-id"]))
    }

    @Test func isAliveAmongIsFalseWhenIdMissing() {
        // Ghost case: the PID may still resolve to *some* process (here a live
        // one), but identity verification rejects it because the id is absent.
        #expect(!makeInfo(pid: getpid()).isAlive(among: ["other-session"]))
    }

    @Test func isAliveAmongIsFalseForEmptyLiveSet() {
        #expect(!makeInfo(pid: getpid()).isAlive(among: []))
    }
}
