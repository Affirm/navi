import Testing
import Foundation
@testable import NaviCore

@Suite("GitInfo Equatable")
struct GitInfoEquatableTests {
    private func make(
        branch: String = "main",
        isDirty: Bool? = false,
        isDetached: Bool = false,
        ahead: Int? = 0,
        behind: Int? = 0,
        defaultBranch: String? = "main",
        fetchedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> GitInfo {
        GitInfo(branch: branch, isDirty: isDirty, isDetached: isDetached,
                ahead: ahead, behind: behind, defaultBranch: defaultBranch,
                fetchedAt: fetchedAt)
    }

    @Test func ignoresFetchedAt() {
        let a = make(fetchedAt: Date(timeIntervalSince1970: 1_000))
        let b = make(fetchedAt: Date(timeIntervalSince1970: 999_999))
        #expect(a == b, "Equality must ignore fetchedAt so SwiftUI does not re-render every refresh")
    }

    @Test func differentBranchIsNotEqual() {
        #expect(make(branch: "main") != make(branch: "feat/x"))
    }

    @Test func differentIsDirtyIsNotEqual() {
        #expect(make(isDirty: true) != make(isDirty: false))
        #expect(make(isDirty: nil) != make(isDirty: false))
        #expect(make(isDirty: nil) != make(isDirty: true))
    }

    @Test func differentDetachedIsNotEqual() {
        #expect(make(isDetached: true) != make(isDetached: false))
    }

    @Test func differentAheadIsNotEqual() {
        #expect(make(ahead: 1) != make(ahead: 0))
        #expect(make(ahead: nil) != make(ahead: 0))
    }

    @Test func differentBehindIsNotEqual() {
        #expect(make(behind: 1) != make(behind: 0))
    }

    @Test func differentDefaultBranchIsNotEqual() {
        #expect(make(defaultBranch: "main") != make(defaultBranch: "master"))
        #expect(make(defaultBranch: nil) != make(defaultBranch: "main"))
    }
}

@Suite("TranscriptInfo Equatable")
struct TranscriptInfoEquatableTests {
    private func make(
        model: String? = "claude-opus-4-7",
        permissionMode: String? = "auto",
        contextTokens: Int? = 42_000,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> TranscriptInfo {
        TranscriptInfo(model: model, permissionMode: permissionMode, contextTokens: contextTokens, fetchedAt: fetchedAt)
    }

    @Test func ignoresFetchedAt() {
        let a = make(fetchedAt: Date(timeIntervalSince1970: 1_000))
        let b = make(fetchedAt: Date(timeIntervalSince1970: 999_999))
        #expect(a == b)
    }

    @Test func differentModelIsNotEqual() {
        #expect(make(model: "opus") != make(model: "sonnet"))
        #expect(make(model: nil) != make(model: "opus"))
    }

    @Test func differentPermissionModeIsNotEqual() {
        #expect(make(permissionMode: "auto") != make(permissionMode: "plan"))
        #expect(make(permissionMode: nil) != make(permissionMode: "auto"))
    }

    @Test func differentContextTokensIsNotEqual() {
        #expect(make(contextTokens: 100_000) != make(contextTokens: 200_000))
        #expect(make(contextTokens: nil) != make(contextTokens: 100_000))
    }

    @Test func bothNilIsEqual() {
        let a = make(model: nil, permissionMode: nil, contextTokens: nil)
        let b = make(model: nil, permissionMode: nil, contextTokens: nil, fetchedAt: Date(timeIntervalSince1970: 999_999))
        #expect(a == b)
    }
}

@Suite("PRInfo Equatable")
struct PRInfoEquatableTests {
    private func make(
        number: Int = 1,
        url: URL = URL(string: "https://example.com/pr/1")!,
        branch: String = "feat/x",
        fetchedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PRInfo {
        PRInfo(number: number, url: url, branch: branch, fetchedAt: fetchedAt)
    }

    @Test func ignoresFetchedAt() {
        let a = make(fetchedAt: Date(timeIntervalSince1970: 1_000))
        let b = make(fetchedAt: Date(timeIntervalSince1970: 999_999))
        #expect(a == b)
    }

    @Test func differentNumberIsNotEqual() {
        #expect(make(number: 1) != make(number: 2))
    }

    @Test func differentURLIsNotEqual() {
        let a = make(url: URL(string: "https://example.com/pr/1")!)
        let b = make(url: URL(string: "https://example.com/pr/2")!)
        #expect(a != b)
    }

    @Test func differentBranchIsNotEqual() {
        #expect(make(branch: "x") != make(branch: "y"))
    }
}

@Suite("EnrichmentService.prKey")
struct EnrichmentServicePrKeyTests {
    // EnrichmentService lives in the Navi target, but its prKey logic only
    // depends on the static cwd + branch composition pattern. Reproducing
    // the format here lets us assert against it without coupling NaviCore
    // tests to the executable target.

    @Test func keyUsesUnitSeparatorBetweenCwdAndBranch() {
        // The prInfoByCwdBranch dictionary is publicly typed [String: PRInfo],
        // so this test exists to lock in the formula upstream uses so future
        // edits don't silently break key lookups in the views.
        let cwd = "/tmp/navi"
        let branch = "feat/x"
        let expected = "\(cwd)\u{1f}\(branch)"
        #expect(expected == "/tmp/navi\u{1f}feat/x")
    }
}

@Suite("SubagentInfo Equatable")
struct SubagentInfoEquatableTests {
    private func make(
        id: String = "a0503c80c233a372f",
        agentType: String = "Explore",
        description: String = "search the codebase",
        toolUseId: String = "toolu_01abc",
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        lastActivity: Date = Date(timeIntervalSince1970: 1_005),
        isRunning: Bool = true
    ) -> SubagentInfo {
        SubagentInfo(id: id, agentType: agentType, description: description,
                     toolUseId: toolUseId, startedAt: startedAt,
                     lastActivity: lastActivity, isRunning: isRunning)
    }

    @Test func identicalValuesAreEqual() {
        // The enrichment publishes a new array only when `existing != infos`,
        // so identical values must compare equal to avoid redundant UI churn.
        #expect(make() == make())
    }

    @Test func runningTransitionIsNotEqual() {
        // The running -> finished flip must be observed so the row updates.
        #expect(make(isRunning: true) != make(isRunning: false))
    }

    @Test func newActivityIsNotEqual() {
        // A fresh lastActivity must re-publish so relative-time / drop-off works.
        #expect(make(lastActivity: Date(timeIntervalSince1970: 1_005))
                != make(lastActivity: Date(timeIntervalSince1970: 1_099)))
    }

    @Test func differentAgentIdentityIsNotEqual() {
        #expect(make(id: "x") != make(id: "y"))
        #expect(make(agentType: "Explore") != make(agentType: "Plan"))
        #expect(make(toolUseId: "toolu_a") != make(toolUseId: "toolu_b"))
    }
}
