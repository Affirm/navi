import Foundation

/// One sub-agent (an `Agent`/`Task` tool invocation) spawned by a session.
///
/// Sub-agents are not separate Claude sessions — they share the parent's
/// `sessionId` and `pid` and never get a `~/.claude/sessions/<pid>.json` entry.
/// The authoritative record lives on disk as a sibling of the transcript at
/// `~/.claude/projects/<project>/<sessionId>/subagents/agent-<agentId>.meta.json`
/// (+ matching `.jsonl`). This value type mirrors that record so the UI can nest
/// each sub-agent under the parent session that spawned it.
public struct SubagentInfo: Identifiable, Equatable {
    public let id: String          // agentId (from the agent-<id>.jsonl filename)
    public let agentType: String   // "Explore", "general-purpose", custom agent name…
    public let description: String // short label from meta.json
    public let toolUseId: String   // parent `Agent` tool_use id — the nesting key
    public let startedAt: Date
    public let lastActivity: Date
    public let isRunning: Bool

    public init(
        id: String,
        agentType: String,
        description: String,
        toolUseId: String,
        startedAt: Date,
        lastActivity: Date,
        isRunning: Bool
    ) {
        self.id = id
        self.agentType = agentType
        self.description = description
        self.toolUseId = toolUseId
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.isRunning = isRunning
    }
}
