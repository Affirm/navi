import SwiftUI
import AppKit
import NaviCore

private func headTruncated(_ path: String, max: Int) -> String {
    if path.count <= max { return path }
    return "\u{2026}" + String(path.suffix(max - 1))
}

private func middleTruncated(_ s: String, max: Int) -> String {
    if s.count <= max { return s }
    let keep = max - 1
    let prefixLen = keep - keep / 2
    let suffixLen = keep - prefixLen
    return String(s.prefix(prefixLen)) + "\u{2026}" + String(s.suffix(suffixLen))
}

private func shortModel(_ raw: String) -> String {
    var s = raw
    if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
    if s.lowercased().hasSuffix("-1m") { s = String(s.dropLast(3)) }
    return s
}

struct SessionSection: View {
    let group: SessionGroup
    @ObservedObject var monitor: EventMonitor
    @ObservedObject var floatingManager: FloatingWindowManager
    @ObservedObject var enrichmentService: EnrichmentService
    @State private var isExpanded = false
    @AppStorage("NaviFontScale") private var s: Double = 1.0

    private var shouldExpand: Bool {
        group.hasPending
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session header
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: group.status.icon)
                                .foregroundStyle(group.status.color)
                                .font(.system(size: 13 * s))

                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 11 * s))
                            Text(group.info.displayName(useSessionName: floatingManager.sessionNamesEnabled))
                                .font(.system(size: 13 * s, weight: .semibold))

                            Text(group.info.shortSession)
                                .font(.system(size: 11 * s, design: .monospaced))
                                .foregroundStyle(.tertiary)

                            Spacer()

                            if !group.status.label.isEmpty {
                                Text(group.status.label)
                                    .font(.system(size: 11 * s, weight: .medium))
                                    .foregroundStyle(group.status.color)
                            }

                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(relativeTime(from: group.info.lastActivity, to: context.date))
                                    .font(.system(size: 11 * s))
                                    .foregroundStyle(.tertiary)
                            }

                            if !group.events.isEmpty {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10 * s, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    if !group.info.tty.isEmpty || group.info.pid > 0 {
                        Button { focusTerminal(tty: group.info.tty, pid: group.info.pid) } label: {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10 * s, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Focus terminal")
                        .padding(.trailing, 6)
                    }

                    Button { monitor.dismissSession(group.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10 * s, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                }

                if floatingManager.anyEnrichmentToggleOn {
                    FlowLayout(spacing: 6) {
                        if floatingManager.showFolderEnabled && !group.info.cwd.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(headTruncated(group.info.cwd, max: 28))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(4)
                            .help(group.info.cwd)
                        }
                        if floatingManager.showGitEnabled,
                           let git = enrichmentService.gitInfoByCwd[group.info.cwd] {
                            let bg: Color = {
                                if git.isDetached { return Color.pastelGray.opacity(0.30) }
                                // Unknown (probe failed / timed out) renders the
                                // same neutral gray as detached HEAD so a green
                                // badge always means "definitely clean."
                                guard let dirty = git.isDirty else { return Color.pastelGray.opacity(0.30) }
                                return dirty ? Color.pastelYellow.opacity(0.30) : Color.pastelGreen.opacity(0.30)
                            }()
                            let display: String = {
                                var text = middleTruncated(git.branch, max: 20)
                                if !git.isDetached, git.isDirty == true { text += "*" }
                                if !git.isDetached, git.defaultBranch != nil,
                                   let a = git.ahead, a > 0 { text += "\u{2191}\(a)" }
                                if !git.isDetached, git.defaultBranch != nil,
                                   let b = git.behind, b > 0 { text += "\u{2193}\(b)" }
                                return text
                            }()
                            let tooltip: String = git.isDirty == nil && !git.isDetached
                                ? "\(git.branch) (status unknown)"
                                : git.branch
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(display)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(bg)
                            .cornerRadius(4)
                            .help(tooltip)
                        }
                        if floatingManager.showGitEnabled,
                           let git = enrichmentService.gitInfoByCwd[group.info.cwd],
                           !git.isDetached, !git.branch.isEmpty,
                           let pr = enrichmentService.prInfoByCwdBranch[EnrichmentService.prKey(cwd: group.info.cwd, branch: git.branch)] {
                            Button {
                                NSWorkspace.shared.open(pr.url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                    Text("#\(String(pr.number))")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Open PR #\(String(pr.number)) in browser")
                        }
                        if floatingManager.showModeEnabled,
                           let mode = enrichmentService.transcriptInfoBySid[group.info.id]?.permissionMode {
                            Text(mode)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.pastelBlue.opacity(0.30))
                                .clipShape(Capsule())
                        }
                        if floatingManager.showModelEnabled,
                           let model = enrichmentService.transcriptInfoBySid[group.info.id]?.model {
                            Text(shortModel(model))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.pastelPurple.opacity(0.30))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }
            }

            // Events
            if isExpanded && !group.events.isEmpty {
                Divider().padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(group.events) { event in
                        EventRow(event: event, monitor: monitor)
                        if event.id != group.events.last?.id {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(group.hasPending ? Color.orange.opacity(0.05) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(group.hasPending ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.horizontal, 6)
        .onAppear {
            if shouldExpand { isExpanded = true }
        }
        .onChange(of: shouldExpand) { _, expand in
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded = expand }
        }
    }
}
