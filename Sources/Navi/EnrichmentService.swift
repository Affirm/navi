import Foundation
import AppKit
import NaviCore

/// One-shot NSLog gate. The first call for a given key emits the message;
/// subsequent calls with the same key are silently dropped. Owner must
/// serialize access (e.g. confine to a single DispatchQueue).
struct LoggedOnce {
    private var keys: Set<String> = []
    mutating func log(key: String, _ message: @autoclosure () -> String) {
        guard !keys.contains(key) else { return }
        keys.insert(key)
        NSLog("%@", message())
    }
}

final class EnrichmentService: ObservableObject, SessionEnrichmentProvider {
    @Published private(set) var gitInfoByCwd: [String: GitInfo] = [:]
    @Published private(set) var transcriptInfoBySid: [String: TranscriptInfo] = [:]
    @Published private(set) var prInfoByCwdBranch: [String: PRInfo] = [:]
    /// Sub-agents (Agent/Task tool invocations) per parent session id, derived
    /// from `<project>/<sessionId>/subagents/agent-*.meta.json` on disk.
    @Published private(set) var subagentsBySid: [String: [SubagentInfo]] = [:]

    private let queue = DispatchQueue(label: "navi.enrichment", qos: .utility)
    private var gitCache: [String: GitInfo] = [:]
    private var pendingRefreshes: Set<String> = []
    private var inFlightRefreshes: Set<String> = []
    private var lastRefreshScheduledByCwd: [String: Date] = [:]
    private var logged = LoggedOnce()
    private var gitAvailable: Bool = true

    private var transcriptCache: [String: TranscriptInfo] = [:]
    private var pendingTranscriptRefreshes: Set<String> = []
    private var inFlightTranscriptRefreshes: Set<String> = []
    private var lastTranscriptRefreshBySid: [String: Date] = [:]

    private var subagentsCache: [String: [SubagentInfo]] = [:]
    private var pendingSubagentRefreshes: Set<String> = []
    private var inFlightSubagentRefreshes: Set<String> = []
    private var lastSubagentRefreshBySid: [String: Date] = [:]

    private var prCache: [String: PRInfo] = [:]
    private var pendingPRRefreshes: Set<String> = []
    private var inFlightPRRefreshes: Set<String> = []
    private var lastPRRefreshByKey: [String: Date] = [:]
    private var ghAvailable: Bool = false
    private var ghProbeDone: Bool = false

    unowned let floatingManager: FloatingWindowManager
    private weak var monitor: EventMonitor?

    /// Per-session highest alert level seen (0 = none, 1 = first threshold, 2 = second).
    /// In-memory only — resets on Navi restart, which is acceptable for informational alerts.
    private var contextAlertLevels: [String: Int] = [:]
    private var contextAlertEventIDs: [String: [String]] = [:]
    private static let contextAlertResetFloor = 140_000

    init(floatingManager: FloatingWindowManager) {
        self.floatingManager = floatingManager
    }

    func attach(monitor: EventMonitor) {
        self.monitor = monitor
    }

    static func prKey(cwd: String, branch: String) -> String {
        "\(cwd)\u{1f}\(branch)"
    }

    func refresh(for session: SessionInfo) {
        guard floatingManager.anyEnrichmentToggleOn else { return }
        let cwd = session.cwd
        guard !cwd.isEmpty else { return }
        // Only spawn git/gh subprocesses when the git badge is actually
        // visible. The folder badge renders `cwd` directly and never reads
        // gitInfoByCwd, so an enabled folder-only configuration shouldn't
        // pay for git probes.
        if floatingManager.showGitEnabled {
            scheduleGitRefresh(cwd: cwd)
        }
        if (floatingManager.showModeEnabled || floatingManager.showModelEnabled || floatingManager.showContextEnabled || floatingManager.contextAlertsEnabled),
           !session.id.isEmpty {
            scheduleTranscriptRefresh(sessionID: session.id, cwd: cwd)
        }
        if floatingManager.showSubagentsEnabled, !session.id.isEmpty {
            scheduleSubagentsRefresh(sessionID: session.id, cwd: cwd)
        }
    }

    private func scheduleGitRefresh(cwd: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.pendingRefreshes.contains(cwd) || self.inFlightRefreshes.contains(cwd) {
                return
            }
            // AC-24: enforce 5s TTL — within 5s of a successful refresh, return cached value
            // without spawning git subprocesses. Mirrors PR cache TTL at schedulePRRefresh.
            if let cached = self.gitCache[cwd],
               Date().timeIntervalSince(cached.fetchedAt) < 5.0 {
                return
            }
            if let last = self.lastRefreshScheduledByCwd[cwd],
               Date().timeIntervalSince(last) < 0.5 {
                self.pendingRefreshes.insert(cwd)
                let delay = 0.5 - Date().timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.pendingRefreshes.remove(cwd)
                    self.runGitRefresh(cwd: cwd)
                }
                return
            }
            self.runGitRefresh(cwd: cwd)
        }
    }

    private func runGitRefresh(cwd: String) {
        // Defensive on-queue reentrancy guard; matches the PR/transcript refresh shape.
        if inFlightRefreshes.contains(cwd) { return }
        inFlightRefreshes.insert(cwd)
        lastRefreshScheduledByCwd[cwd] = Date()
        defer { inFlightRefreshes.remove(cwd) }

        guard gitAvailable else { return }

        guard let branchProbe = runProcess(executable: "git", args: ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]) else {
            return
        }
        if branchProbe.exitCode != 0 {
            gitCache.removeValue(forKey: cwd)
            DispatchQueue.main.async { [weak self] in
                self?.gitInfoByCwd.removeValue(forKey: cwd)
            }
            return
        }
        let rawBranch = branchProbe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var branch = rawBranch
        var isDetached = false
        if rawBranch == "HEAD" {
            isDetached = true
            if let sha = runProcess(executable: "git", args: ["-C", cwd, "rev-parse", "--short", "HEAD"]),
               sha.exitCode == 0 {
                branch = sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // diff-index is exit-code-only and skips the untracked-file walk that
        // makes `git status --porcelain` slow (and prone to hitting our 2s cap)
        // on large monorepos. Exit 0 = clean tracked, exit 1 = dirty tracked.
        // ls-files --others picks up untracked-only dirtiness.
        // nil result (timeout / fork error) propagates as `isDirty == nil` so
        // the view can render "unknown" rather than silently misrepresenting
        // a dirty repo as clean.
        var isDirty: Bool? = nil
        if let trackedDiff = runProcess(executable: "git", args: ["-C", cwd, "diff-index", "--quiet", "HEAD", "--"]) {
            if trackedDiff.exitCode == 0 {
                isDirty = false
                if let untracked = runProcess(executable: "git", args: ["-C", cwd, "ls-files", "--others", "--exclude-standard"]),
                   untracked.exitCode == 0,
                   !untracked.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    isDirty = true
                }
            } else if trackedDiff.exitCode == 1 {
                isDirty = true
            }
            // Any other exit code (rare: e.g. orphan branch with no HEAD)
            // leaves isDirty == nil → unknown.
        }

        var defaultBranch: String? = nil
        if let head = runProcess(executable: "git", args: ["-C", cwd, "symbolic-ref", "refs/remotes/origin/HEAD", "--short"]),
           head.exitCode == 0 {
            let value = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("origin/") {
                defaultBranch = String(value.dropFirst("origin/".count))
            } else if !value.isEmpty {
                defaultBranch = value
            }
        }
        if defaultBranch == nil,
           let main = runProcess(executable: "git", args: ["-C", cwd, "show-ref", "--verify", "refs/heads/main"]),
           main.exitCode == 0 {
            defaultBranch = "main"
        }
        if defaultBranch == nil,
           let master = runProcess(executable: "git", args: ["-C", cwd, "show-ref", "--verify", "refs/heads/master"]),
           master.exitCode == 0 {
            defaultBranch = "master"
        }

        var ahead: Int? = nil
        var behind: Int? = nil
        if !isDetached, let def = defaultBranch, def != branch {
            if let counts = runProcess(executable: "git", args: ["-C", cwd, "rev-list", "--left-right", "--count", "\(branch)...\(def)"]),
               counts.exitCode == 0 {
                let parts = counts.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == "\t" || $0 == " " })
                if parts.count == 2,
                   let leftCount = Int(parts[0]),
                   let rightCount = Int(parts[1]) {
                    ahead = leftCount
                    behind = rightCount
                }
            }
        } else if !isDetached, let def = defaultBranch, def == branch {
            ahead = 0
            behind = 0
        }

        let newInfo = GitInfo(
            branch: branch,
            isDirty: isDirty,
            isDetached: isDetached,
            ahead: ahead,
            behind: behind,
            defaultBranch: defaultBranch,
            fetchedAt: Date()
        )

        let prevBranch = gitCache[cwd]?.branch
        gitCache[cwd] = newInfo
        if let prev = prevBranch, prev != newInfo.branch {
            handleBranchSwitch(cwd: cwd, oldBranch: prev)
        }

        DispatchQueue.main.async { [weak self] in
            self?.gitInfoByCwd[cwd] = newInfo
        }

        if floatingManager.showGitEnabled,
           !newInfo.isDetached, !newInfo.branch.isEmpty {
            schedulePRRefresh(cwd: cwd, branch: newInfo.branch)
        }
    }

    private func handleBranchSwitch(cwd: String, oldBranch: String) {
        invalidatePRCache(cwd: cwd, branch: oldBranch)
    }

    private func probeGhAvailability() {
        guard !ghProbeDone else { return }
        ghProbeDone = true

        let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        let installed = candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
        if !installed {
            ghAvailable = false
            logged.log(key: "gh-not-found", "[Navi] gh not found on PATH; PR enrichment disabled.")
            return
        }

        guard let auth = runProcess(executable: "gh", args: ["auth", "status"]) else {
            ghAvailable = false
            logged.log(key: "gh-auth-failed", "[Navi] gh authentication failed; PR enrichment disabled.")
            return
        }
        if auth.exitCode == 0 {
            ghAvailable = true
        } else {
            ghAvailable = false
            logged.log(key: "gh-auth-failed", "[Navi] gh authentication failed; PR enrichment disabled.")
        }
    }

    private func schedulePRRefresh(cwd: String, branch: String) {
        let key = Self.prKey(cwd: cwd, branch: branch)
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.ghProbeDone {
                self.probeGhAvailability()
            }
            guard self.ghAvailable else { return }
            if self.pendingPRRefreshes.contains(key) || self.inFlightPRRefreshes.contains(key) {
                return
            }
            if let cached = self.prCache[key],
               Date().timeIntervalSince(cached.fetchedAt) < 60 {
                return
            }
            if let last = self.lastPRRefreshByKey[key],
               Date().timeIntervalSince(last) < 0.5 {
                self.pendingPRRefreshes.insert(key)
                let delay = 0.5 - Date().timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.pendingPRRefreshes.remove(key)
                    self.runPRRefresh(cwd: cwd, branch: branch)
                }
                return
            }
            self.runPRRefresh(cwd: cwd, branch: branch)
        }
    }

    private func runPRRefresh(cwd: String, branch: String) {
        guard ghAvailable else { return }
        if branch.isEmpty || branch == "HEAD" { return }

        let key = Self.prKey(cwd: cwd, branch: branch)
        if inFlightPRRefreshes.contains(key) { return }
        inFlightPRRefreshes.insert(key)
        lastPRRefreshByKey[key] = Date()
        // runs synchronously on the serial queue, so defer is safe.
        defer { inFlightPRRefreshes.remove(key) }

        guard let result = runProcess(
            executable: "gh",
            args: ["pr", "list", "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"],
            cwd: cwd
        ) else {
            return
        }

        if result.exitCode != 0 {
            logged.log(key: "gh-pr-list-failed", "[Navi] gh pr list failed; preserving cached PR data.")
            return
        }

        guard let data = result.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        if arr.isEmpty {
            if prCache.removeValue(forKey: key) != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.prInfoByCwdBranch.removeValue(forKey: key)
                }
            }
            return
        }

        guard let first = arr.first,
              let number = first["number"] as? Int,
              let urlString = first["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }

        let newInfo = PRInfo(number: number, url: url, branch: branch, fetchedAt: Date())
        let existing = prCache[key]
        if existing == newInfo { return }
        prCache[key] = newInfo
        DispatchQueue.main.async { [weak self] in
            self?.prInfoByCwdBranch[key] = newInfo
        }
    }

    private func invalidatePRCache(cwd: String, branch: String) {
        let key = Self.prKey(cwd: cwd, branch: branch)
        if prCache.removeValue(forKey: key) != nil {
            DispatchQueue.main.async { [weak self] in
                self?.prInfoByCwdBranch.removeValue(forKey: key)
            }
        }
        pendingPRRefreshes.remove(key)
        lastPRRefreshByKey.removeValue(forKey: key)
    }

    // Drop all sid-keyed caches for a session that's been dismissed.
    // Called from EventMonitor.dismissSession / clearAll. Runs at human
    // rate so the queue.async hop is fine.
    func evict(sessionID: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let dropped = self.transcriptCache.removeValue(forKey: sessionID) != nil
            self.pendingTranscriptRefreshes.remove(sessionID)
            self.lastTranscriptRefreshBySid.removeValue(forKey: sessionID)
            // inFlightTranscriptRefreshes is left alone — the running task
            // will clear its own entry via `defer` when it completes.
            if dropped {
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptInfoBySid.removeValue(forKey: sessionID)
                }
            }
            let droppedSubagents = self.subagentsCache.removeValue(forKey: sessionID) != nil
            self.pendingSubagentRefreshes.remove(sessionID)
            self.lastSubagentRefreshBySid.removeValue(forKey: sessionID)
            if droppedSubagents {
                DispatchQueue.main.async { [weak self] in
                    self?.subagentsBySid.removeValue(forKey: sessionID)
                }
            }
            self.contextAlertLevels.removeValue(forKey: sessionID)
            if let alertIDs = self.contextAlertEventIDs.removeValue(forKey: sessionID) {
                let monitor = self.monitor
                DispatchQueue.main.async { alertIDs.forEach { monitor?.dismiss($0) } }
            }
        }
    }

    // Drop cwd-keyed and (cwd, branch)-keyed caches for cwds no longer
    // referenced by any active session. Caller passes the current set of
    // active cwds (e.g. EventMonitor's session map). Anything outside that
    // set is evicted. Bounded by the number of cwds the user has ever
    // opened, walked at human rate.
    func evictUnused(activeCwds: Set<String>) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let staleCwds = self.gitCache.keys.filter { !activeCwds.contains($0) }
                + self.lastRefreshScheduledByCwd.keys.filter { !activeCwds.contains($0) }
            let uniqueStaleCwds = Set(staleCwds)
            for cwd in uniqueStaleCwds {
                self.gitCache.removeValue(forKey: cwd)
                self.pendingRefreshes.remove(cwd)
                self.lastRefreshScheduledByCwd.removeValue(forKey: cwd)
            }
            // PR keys are "<cwd>\u{1f}<branch>" — strip the branch suffix to
            // identify the cwd component.
            let stalePRKeys = self.prCache.keys.filter { key in
                guard let sep = key.firstIndex(of: "\u{1f}") else { return false }
                return !activeCwds.contains(String(key[..<sep]))
            }
            for key in stalePRKeys {
                self.prCache.removeValue(forKey: key)
                self.pendingPRRefreshes.remove(key)
                self.lastPRRefreshByKey.removeValue(forKey: key)
            }
            if !uniqueStaleCwds.isEmpty || !stalePRKeys.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    for cwd in uniqueStaleCwds {
                        self.gitInfoByCwd.removeValue(forKey: cwd)
                    }
                    for key in stalePRKeys {
                        self.prInfoByCwdBranch.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    private func scheduleTranscriptRefresh(sessionID: String, cwd: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.pendingTranscriptRefreshes.contains(sessionID) ||
               self.inFlightTranscriptRefreshes.contains(sessionID) {
                return
            }
            // Mirror the git-refresh 5 s TTL: skip the file read entirely if a
            // recent transcript fetch already populated the cache. Cuts I/O on
            // busy sessions where every hook event would otherwise re-tail the
            // jsonl file.
            if let cached = self.transcriptCache[sessionID],
               Date().timeIntervalSince(cached.fetchedAt) < 5.0 {
                return
            }
            if let last = self.lastTranscriptRefreshBySid[sessionID],
               Date().timeIntervalSince(last) < 0.5 {
                self.pendingTranscriptRefreshes.insert(sessionID)
                let delay = 0.5 - Date().timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.pendingTranscriptRefreshes.remove(sessionID)
                    self.runTranscriptRefresh(sessionID: sessionID, cwd: cwd)
                }
                return
            }
            self.runTranscriptRefresh(sessionID: sessionID, cwd: cwd)
        }
    }

    private func runTranscriptRefresh(sessionID: String, cwd: String) {
        if inFlightTranscriptRefreshes.contains(sessionID) { return }
        inFlightTranscriptRefreshes.insert(sessionID)
        lastTranscriptRefreshBySid[sessionID] = Date()
        defer { inFlightTranscriptRefreshes.remove(sessionID) }

        guard let url = transcriptURL(forSessionID: sessionID, cwd: cwd) else {
            if transcriptCache.removeValue(forKey: sessionID) != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptInfoBySid.removeValue(forKey: sessionID)
                }
            }
            return
        }

        guard let lines = readTranscriptTail(url: url) else {
            if transcriptCache.removeValue(forKey: sessionID) != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptInfoBySid.removeValue(forKey: sessionID)
                }
            }
            return
        }

        var model: String? = nil
        var permissionMode: String? = nil
        var contextTokens: Int? = nil
        var consecutiveParseFailures = 0
        var maxConsecutiveFailures = 0
        for line in lines.reversed() {
            if model != nil && permissionMode != nil && contextTokens != nil { break }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                consecutiveParseFailures += 1
                maxConsecutiveFailures = max(maxConsecutiveFailures, consecutiveParseFailures)
                continue
            }
            consecutiveParseFailures = 0
            if let message = obj["message"] as? [String: Any],
               (obj["type"] as? String) == "assistant" || (message["role"] as? String) == "assistant" {
                if model == nil, let m = message["model"] as? String, !m.isEmpty {
                    model = m
                }
                // Sum all input-side token counters; bare input_tokens alone understates
                // context by orders of magnitude when prompt caching is active.
                if contextTokens == nil, let usage = message["usage"] as? [String: Any] {
                    let input  = usage["input_tokens"] as? Int ?? 0
                    let cread  = usage["cache_read_input_tokens"] as? Int ?? 0
                    let ccreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let total = input + cread + ccreate
                    if total > 0 { contextTokens = total }
                }
            }
            if permissionMode == nil {
                if let pm = obj["permissionMode"] as? String, !pm.isEmpty {
                    permissionMode = pm
                } else if let message = obj["message"] as? [String: Any],
                          let pm = message["permissionMode"] as? String, !pm.isEmpty {
                    permissionMode = pm
                }
            }
        }
        if maxConsecutiveFailures >= 3 {
            logged.log(
                key: "transcript-parse-error-\(sessionID)",
                "[Navi] transcript parse error for session \(sessionID): \(maxConsecutiveFailures) consecutive lines failed to parse"
            )
        }

        let existing = transcriptCache[sessionID]
        if model == nil && permissionMode == nil && contextTokens == nil && existing == nil {
            return
        }

        let newInfo = TranscriptInfo(model: model, permissionMode: permissionMode, contextTokens: contextTokens, fetchedAt: Date())
        if existing == newInfo { return }
        transcriptCache[sessionID] = newInfo

        if floatingManager.contextAlertsEnabled, let tokens = contextTokens {
            checkContextAlert(sessionID: sessionID, tokens: tokens, cwd: cwd)
        }

        DispatchQueue.main.async { [weak self] in
            self?.transcriptInfoBySid[sessionID] = newInfo
        }
    }

    private func checkContextAlert(sessionID: String, tokens: Int, cwd: String) {
        let t1 = floatingManager.contextAlertThreshold1
        let t2 = floatingManager.contextAlertThreshold2
        let thresholds = [t1, t2].filter { $0 > 0 }.sorted()

        let current = contextAlertLevels[sessionID] ?? 0

        if tokens < Self.contextAlertResetFloor && current > 0 {
            contextAlertLevels[sessionID] = 0
            if let ids = contextAlertEventIDs.removeValue(forKey: sessionID) {
                ids.forEach { monitor?.dismiss($0) }
            }
            return
        }

        let newLevel = thresholds.filter { tokens >= $0 }.count
        guard newLevel > current else { return }
        contextAlertLevels[sessionID] = newLevel

        let crossedK = thresholds[newLevel - 1] / 1_000
        let tokensK = tokens / 1_000
        let ts = Date()
        let alertID = "\(Int(ts.timeIntervalSince1970))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        contextAlertEventIDs[sessionID, default: []].append(alertID)
        let event = NaviEvent(
            id: alertID,
            timestamp: ts,
            type: "info",
            title: "Context window",
            body: "\(tokensK)K tokens — past \(crossedK)K threshold. Consider /compact or starting a new session.",
            description: "",
            sessionID: sessionID,
            sessionName: "",
            pid: 0,
            cwd: cwd,
            tty: "",
            toolUseID: "",
            expires: nil
        )
        monitor?.receiveAlert(event)
    }

    private func scheduleSubagentsRefresh(sessionID: String, cwd: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.pendingSubagentRefreshes.contains(sessionID) ||
               self.inFlightSubagentRefreshes.contains(sessionID) {
                return
            }
            // Unlike git/transcript, there's no cache-TTL early-return here: sub-agent
            // state changes at hook-event frequency, so each event triggers a fresh
            // scan. The 0.5 s debounce only coalesces bursts of near-simultaneous
            // events; the in-flight guard serializes the rest so they never pile up.
            if let last = self.lastSubagentRefreshBySid[sessionID],
               Date().timeIntervalSince(last) < 0.5 {
                self.pendingSubagentRefreshes.insert(sessionID)
                let delay = 0.5 - Date().timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.pendingSubagentRefreshes.remove(sessionID)
                    self.runSubagentsRefresh(sessionID: sessionID, cwd: cwd)
                }
                return
            }
            self.runSubagentsRefresh(sessionID: sessionID, cwd: cwd)
        }
    }

    private func runSubagentsRefresh(sessionID: String, cwd: String) {
        if inFlightSubagentRefreshes.contains(sessionID) { return }
        inFlightSubagentRefreshes.insert(sessionID)
        lastSubagentRefreshBySid[sessionID] = Date()
        defer { inFlightSubagentRefreshes.remove(sessionID) }

        // The subagents dir is a sibling of the transcript:
        // <project>/<sessionId>/subagents/. Reuse transcriptURL so we inherit
        // its direct-then-scan project-encoding fallback.
        let fm = FileManager.default
        guard let transcript = transcriptURL(forSessionID: sessionID, cwd: cwd) else {
            clearSubagents(sessionID: sessionID)
            return
        }
        let subagentsDir = transcript
            .deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)

        guard let entries = try? fm.contentsOfDirectory(atPath: subagentsDir.path) else {
            clearSubagents(sessionID: sessionID)
            return
        }

        // Completed sub-agents have a matching tool_result in the parent
        // transcript; running ones do not. Collect the completed set once.
        let completed = completedToolUseIDs(transcriptURL: transcript)
        let now = Date()

        var infos: [SubagentInfo] = []
        for entry in entries where entry.hasPrefix("agent-") && entry.hasSuffix(".meta.json") {
            let agentID = String(entry.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard !agentID.isEmpty else { continue }
            let metaURL = subagentsDir.appendingPathComponent(entry, isDirectory: false)
            guard let data = fm.contents(atPath: metaURL.path),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let agentType = meta["agentType"] as? String ?? ""
            let description = meta["description"] as? String ?? ""
            let toolUseID = meta["toolUseId"] as? String ?? ""

            // Timestamps come from the transcript .jsonl file attributes — cheap,
            // no parse. creationDate = startedAt, modificationDate = lastActivity.
            // Fall back to the meta file (which we just read, so it exists) if the
            // .jsonl hasn't been created yet — using a fresh Date() here would make
            // the value unstable across refreshes and defeat the `existing == infos`
            // dedup, republishing every hook event until the .jsonl appears.
            let jsonlURL = subagentsDir.appendingPathComponent("agent-\(agentID).jsonl", isDirectory: false)
            let attrs = (try? fm.attributesOfItem(atPath: jsonlURL.path))
                ?? (try? fm.attributesOfItem(atPath: metaURL.path))
            let startedAt = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? .distantPast
            let lastActivity = (attrs?[.modificationDate] as? Date) ?? startedAt

            // Running = the parent has no tool_result for this Agent call yet.
            // The mtime backstop means that on the next refresh a long-idle
            // sub-agent stops showing "running" even if its tool_result ever falls
            // outside the scanned window (e.g. a background agent in a very busy
            // session). Note: isRunning is only recomputed when a hook event drives
            // a refresh, not by the view's 1 s timer, so the flip happens on the
            // next event for the session rather than exactly at 60 s.
            let isRunning = !toolUseID.isEmpty
                && !completed.contains(toolUseID)
                && now.timeIntervalSince(lastActivity) < 60
            infos.append(SubagentInfo(
                id: agentID,
                agentType: agentType,
                description: description,
                toolUseId: toolUseID,
                startedAt: startedAt,
                lastActivity: lastActivity,
                isRunning: isRunning
            ))
        }

        infos.sort { $0.startedAt < $1.startedAt }

        let existing = subagentsCache[sessionID] ?? []
        if existing == infos {
            if infos.isEmpty { subagentsCache.removeValue(forKey: sessionID) }
            return
        }
        if infos.isEmpty {
            clearSubagents(sessionID: sessionID)
            return
        }
        subagentsCache[sessionID] = infos
        DispatchQueue.main.async { [weak self] in
            self?.subagentsBySid[sessionID] = infos
        }
    }

    /// Scan the parent transcript for tool_result blocks and return the set of
    /// tool_use_ids they resolve. A sub-agent whose spawning Agent tool_use id is
    /// in this set has finished. Reads a generous 2 MB tail: the default 64 KB is
    /// far too small here — a finished sub-agent's tool_result gets buried under
    /// subsequent parent activity, leaving it stuck looking "running". 2 MB
    /// covers far more recent turns than any sub-agent inside the display window
    /// could be pushed out by, while staying bounded on multi-MB transcripts.
    private func completedToolUseIDs(transcriptURL: URL) -> Set<String> {
        guard let lines = readTranscriptTail(url: transcriptURL, maxBytes: 2_000_000) else { return [] }
        var completed = Set<String>()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content where (block["type"] as? String) == "tool_result" {
                if let id = block["tool_use_id"] as? String { completed.insert(id) }
            }
        }
        return completed
    }

    private func clearSubagents(sessionID: String) {
        if subagentsCache.removeValue(forKey: sessionID) != nil {
            DispatchQueue.main.async { [weak self] in
                self?.subagentsBySid.removeValue(forKey: sessionID)
            }
        }
    }

    private func transcriptURL(forSessionID sessionID: String, cwd: String) -> URL? {
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let direct = projectsRoot
            .appendingPathComponent(encodedProjectDir(forCwd: cwd), isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // Fallback: scan one level under ~/.claude/projects/ for <sessionID>.jsonl.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: projectsRoot,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])
        else { return nil }
        for dir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Best-effort approximation of Claude Code's project-directory naming
    /// scheme inside `~/.claude/projects/`. The real scheme has historically
    /// shifted, so the direct lookup in `transcriptURL(forSessionID:cwd:)`
    /// often misses and we rely on the directory-scan fallback. Treat the
    /// direct lookup as a fast path, not a contract.
    private func encodedProjectDir(forCwd cwd: String) -> String {
        cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func readTranscriptTail(url: URL, maxBytes: Int = 65_536) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return nil }
        let start = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        var data = handle.readDataToEndOfFile()
        if data.isEmpty { return nil }

        if start > 0 {
            guard let firstNewline = data.firstIndex(of: 0x0A) else { return nil }
            data = data.subdata(in: data.index(after: firstNewline)..<data.endIndex)
        }

        // Swift 6.3 has an ambiguous Sequence/Collection split overload on Data;
        // build the result manually to sidestep it.
        var lines: [Data] = []
        var lineStart = data.startIndex
        for i in data.indices {
            if data[i] == 0x0A {
                if i > lineStart {
                    lines.append(data.subdata(in: lineStart..<i))
                }
                lineStart = data.index(after: i)
            }
        }
        if lineStart < data.endIndex {
            lines.append(data.subdata(in: lineStart..<data.endIndex))
        }
        return lines
    }

    private func runProcess(executable: String, args: [String], cwd: String? = nil, timeout: TimeInterval = 2.0) -> (stdout: String, exitCode: Int32)? {
        let process = Process()
        let candidatePaths: [String]
        if executable == "git" {
            candidatePaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        } else if executable == "gh" {
            candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        } else {
            candidatePaths = []
        }

        var resolvedPath: String? = nil
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            resolvedPath = path
            break
        }

        if let path = resolvedPath {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
        }

        if let cwd = cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently with the wait. macOS pipe buffers are
        // 16-64 KB; without concurrent draining, a child writing more than the
        // buffer blocks on the kernel write and never exits, deadlocking us.
        let drainLock = NSLock()
        var outBuf = Data()
        var errBuf = Data()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            drainLock.lock()
            outBuf.append(chunk)
            drainLock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            drainLock.lock()
            errBuf.append(chunk)
            drainLock.unlock()
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if executable == "git" {
                logged.log(key: "git-not-found", "[Navi] git not found on PATH; git enrichment disabled.")
                gitAvailable = false
            }
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            logged.log(key: "subprocess-timeout-\(executable)", "[Navi] subprocess timeout: \(executable)")
            return nil
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Read any final bytes the kernel had buffered between the last
        // readability fire and the termination signal.
        let outTail = outPipe.fileHandleForReading.availableData
        let errTail = errPipe.fileHandleForReading.availableData
        drainLock.lock()
        if !outTail.isEmpty { outBuf.append(outTail) }
        if !errTail.isEmpty { errBuf.append(errTail) }
        let outData = outBuf
        drainLock.unlock()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        return (stdout, process.terminationStatus)
    }
}
