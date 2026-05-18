import Testing
@testable import NaviCore

@Suite("SessionStatus")
struct SessionStatusTests {
    @Test func needsAttentionIcon() {
        #expect(SessionStatus.needsAttention.icon == "exclamationmark.circle.fill")
    }

    @Test func workingIcon() {
        #expect(SessionStatus.working.icon == "gearshape.circle.fill")
    }

    @Test func waitingForInputIcon() {
        #expect(SessionStatus.waitingForInput.icon == "ellipsis.circle.fill")
    }

    @Test func idleIcon() {
        #expect(SessionStatus.idle.icon == "checkmark.circle.fill")
    }

    @Test func needsAttentionLabel() {
        #expect(SessionStatus.needsAttention.label == "Needs attention")
    }

    @Test func workingLabel() {
        #expect(SessionStatus.working.label == "Working")
    }

    @Test func waitingForInputLabel() {
        #expect(SessionStatus.waitingForInput.label == "Idle")
    }

    @Test func idleLabelIsEmpty() {
        // The .idle case is deliberately label-less in the UI.
        #expect(SessionStatus.idle.label == "")
    }
}
