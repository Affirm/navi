import SwiftUI
import AppKit
import NaviCore

/// Owns the "Remote Hosts" window (opened from Settings → Experimental).
final class RemoteHostsWindow {
    static let shared = RemoteHostsWindow()
    private var window: NSWindow?
    private weak var floatingManager: FloatingWindowManager?
    private weak var bridge: RemoteBridge?

    func configure(floatingManager: FloatingWindowManager, bridge: RemoteBridge) {
        self.floatingManager = floatingManager
        self.bridge = bridge
    }

    func show() {
        guard let floatingManager, let bridge else { return }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "Remote Hosts"
            w.isReleasedWhenClosed = false
            w.level = .floating  // stay above Navi's floating window
            w.contentView = NSHostingView(rootView: RemoteHostsView(
                floatingManager: floatingManager, bridge: bridge))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Model

@MainActor
final class RemoteHostsModel: ObservableObject {
    enum ProbeState: Equatable {
        case running
        case done(HostProbe.Result)
        case failed(String)
    }

    enum ActionKind: String {
        case install = "Install Navi"
        case offlineInstall = "Install Navi from this Mac"
        case uninstall = "Uninstall Navi"
    }

    struct PendingAction: Identifiable {
        let alias: String
        let kind: ActionKind
        let steps: [RemoteInstall.Step]
        let uploadFrom: String?
        var id: String { "\(alias)/\(kind.rawValue)" }

        var displayCommands: [String] {
            var lines: [String] = []
            if let uploadFrom {
                lines.append(RemoteInstall.uploadDisplayCommand(pluginDir: uploadFrom, alias: alias))
            }
            lines += steps.map { RemoteInstall.displayCommand(alias: alias, step: $0) }
            return lines
        }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let ok: Bool
        let text: String
    }

    @Published var sshAliases: [String] = []
    @Published var resolved: [String: SSHEffectiveConfig] = [:]
    @Published var probes: [String: ProbeState] = [:]
    @Published var pending: PendingAction?
    @Published var running: Set<String> = []
    @Published var logs: [String: [LogLine]] = [:]

    let localPluginDir = RemoteInstall.localPluginDir()

    func refreshSSHConfig() {
        Task.detached(priority: .userInitiated) {
            let aliases = SSHConfigParser.hostAliases()
            await MainActor.run { self.sshAliases = aliases }
            for alias in aliases {
                let out = await ProcessRunner.run(SSHEffectiveConfig.resolveSpec(alias: alias), timeout: 5)
                guard out.exitCode == 0 else { continue }
                let cfg = SSHEffectiveConfig.parse(out.stdout)
                await MainActor.run { self.resolved[alias] = cfg }
            }
        }
    }

    func test(_ alias: String) {
        probes[alias] = .running
        Task {
            let spec = RemoteLaunchSpec(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: RelayCommand.sshArguments(alias: alias, remoteCommand: HostProbe.remoteCommand))
            let out = await ProcessRunner.run(spec, timeout: 30)
            if out.timedOut {
                probes[alias] = .failed("Timed out connecting to \(alias).")
            } else if out.exitCode == 255 {
                probes[alias] = .failed(RemoteErrorHint.describe(alias: alias, exitCode: 255, stderr: out.stderr))
            } else {
                probes[alias] = .done(HostProbe.parse(out.stdout))
            }
        }
    }

    private var knownVersion: [String: ClaudeVersion] {
        probes.compactMapValues { if case let .done(r) = $0 { return r.version } else { return nil } }
    }

    func request(_ kind: ActionKind, for alias: String) {
        let version = knownVersion[alias]
        switch kind {
        case .install:
            pending = PendingAction(alias: alias, kind: kind,
                                    steps: RemoteInstall.installSteps(version: version), uploadFrom: nil)
        case .offlineInstall:
            guard let dir = localPluginDir else { return }
            pending = PendingAction(alias: alias, kind: kind,
                                    steps: RemoteInstall.offlineInstallSteps(version: version), uploadFrom: dir)
        case .uninstall:
            pending = PendingAction(alias: alias, kind: kind,
                                    steps: RemoteInstall.uninstallSteps(), uploadFrom: nil)
        }
    }

    /// Runs only after the user confirmed the exact commands in the sheet.
    func runConfirmed(_ action: PendingAction) {
        pending = nil
        let alias = action.alias
        running.insert(alias)
        logs[alias] = []
        Task {
            defer { running.remove(alias) }
            if let dir = action.uploadFrom {
                let out = await ProcessRunner.run(RemoteInstall.uploadSpec(pluginDir: dir, alias: alias), timeout: 180)
                guard out.exitCode == 0, !out.timedOut else {
                    let msg = out.timedOut ? "Timed out" :
                        RemoteErrorHint.describe(alias: alias, exitCode: out.exitCode, stderr: out.stderr)
                    log(alias, false, "Copy plugin to \(RemoteInstall.offlineDir): \(msg)")
                    return
                }
                log(alias, true, "Copied plugin to \(RemoteInstall.offlineDir)")
            }
            for step in action.steps {
                guard await run(step, alias: alias) else { return }
            }
            switch action.kind {
            case .install, .offlineInstall:
                log(alias, true, "Installed. Restart Claude Code sessions already running on \(alias) so the hooks load.")
            case .uninstall:
                log(alias, true, "Uninstalled. Running sessions keep the hooks until restarted.")
            }
        }
    }

    private func run(_ step: RemoteInstall.Step, alias: String) async -> Bool {
        let out = await ProcessRunner.run(RemoteInstall.spec(alias: alias, step: step), timeout: 180)
        let outcome = RemoteInstall.interpret(step: step, alias: alias, output: out)
        if outcome.needsFallback {
            log(alias, true, "\(step.title): \(outcome.message)")
            for fb in step.fallback {
                guard await run(fb, alias: alias) else { return false }
            }
            return true
        }
        log(alias, outcome.ok, "\(step.title): \(outcome.message)")
        return outcome.ok
    }

    private func log(_ alias: String, _ ok: Bool, _ text: String) {
        logs[alias, default: []].append(LogLine(ok: ok, text: text))
    }
}

// MARK: - Views

struct RemoteHostsView: View {
    @ObservedObject var floatingManager: FloatingWindowManager
    @ObservedObject var bridge: RemoteBridge
    @StateObject private var model = RemoteHostsModel()
    @State private var manualEntry = ""

    private var addedAliases: Set<String> { Set(floatingManager.remoteHosts.map(\.alias)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                hostsSection
                addSection
            }
            .padding(16)
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { model.refreshSSHConfig() }
        .sheet(item: $model.pending) { action in
            ConfirmCommandsSheet(action: action,
                                 onCancel: { model.pending = nil },
                                 onRun: { model.runConfirmed(action) })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { floatingManager.remoteHostsEnabled },
                                 set: { floatingManager.remoteHostsEnabled = $0 })) {
                Text("Monitor Claude Code sessions on remote hosts").font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            Text("Navi connects over SSH (BatchMode, your ~/.ssh/config and agent) only to hosts you add here, and streams session events through a small relay that runs for as long as the connection is open. Nothing listens on a network port. The host needs Claude Code with the Navi plugin installed, and python3.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hostsSection: some View {
        GroupBox("Your hosts") {
            VStack(alignment: .leading, spacing: 10) {
                if floatingManager.remoteHosts.isEmpty {
                    Text("No hosts yet. Add one below.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(floatingManager.remoteHosts) { host in
                    HostRow(host: host,
                            featureOn: floatingManager.remoteHostsEnabled,
                            state: bridge.states[host.alias],
                            model: model,
                            onToggle: { on in setEnabled(host.alias, on) },
                            onReconnect: { bridge.reconnectNow(host.alias) },
                            onRemove: { floatingManager.remoteHosts.removeAll { $0.alias == host.alias } })
                    if host.alias != floatingManager.remoteHosts.last?.alias { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var addSection: some View {
        GroupBox("Add a host") {
            VStack(alignment: .leading, spacing: 8) {
                let candidates = model.sshAliases.filter { !addedAliases.contains($0) }
                HStack {
                    Text("From ~/.ssh/config").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Refresh") { model.refreshSSHConfig() }.controlSize(.small)
                }
                if candidates.isEmpty {
                    Text(model.sshAliases.isEmpty ? "No Host entries found." : "All Host entries are added.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(candidates, id: \.self) { alias in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alias).font(.system(size: 12, weight: .medium))
                            if let cfg = model.resolved[alias], !cfg.summary.isEmpty {
                                Text(cfg.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Add") { add(alias) }.controlSize(.small)
                    }
                }
                Divider()
                HStack {
                    TextField("user@host", text: $manualEntry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addManual() }
                    Button("Add") { addManual() }
                        .disabled(!RemoteHostConfig.isValidAlias(manualEntry.trimmingCharacters(in: .whitespaces)))
                }
                Text("For a custom port or jump host, add a Host entry to ~/.ssh/config and pick it above.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func add(_ alias: String) {
        guard RemoteHostConfig.isValidAlias(alias), !addedAliases.contains(alias) else { return }
        floatingManager.remoteHosts.append(RemoteHostConfig(alias: alias))
    }

    private func addManual() {
        let alias = manualEntry.trimmingCharacters(in: .whitespaces)
        guard RemoteHostConfig.isValidAlias(alias) else { return }
        add(alias)
        manualEntry = ""
    }

    private func setEnabled(_ alias: String, _ on: Bool) {
        guard let i = floatingManager.remoteHosts.firstIndex(where: { $0.alias == alias }) else { return }
        floatingManager.remoteHosts[i].enabled = on
    }
}

private struct HostRow: View {
    let host: RemoteHostConfig
    let featureOn: Bool
    let state: RemoteBridge.HostState?
    @ObservedObject var model: RemoteHostsModel
    let onToggle: (Bool) -> Void
    let onReconnect: () -> Void
    let onRemove: () -> Void

    private var statusText: (String, Color) {
        if !featureOn { return ("Off", .secondary) }
        if !host.enabled { return ("Paused", .secondary) }
        switch state?.status {
        case .connected?: return ("Connected", .green)
        case .disconnected?: return ("Disconnected", .orange)
        case .connecting?, nil: return ("Connecting…", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(statusText.1).frame(width: 8, height: 8)
                Text(host.alias).font(.system(size: 13, weight: .semibold))
                Text(statusText.0).font(.system(size: 11)).foregroundStyle(statusText.1)
                if let user = state?.remoteUser, let h = state?.remoteHostname, !user.isEmpty {
                    Text("\(user)@\(h)").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { host.enabled }, set: onToggle))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(host.enabled ? "Pause monitoring this host" : "Resume monitoring this host")
            }
            if featureOn, host.enabled, state?.status == .disconnected, let err = state?.lastError {
                HStack(alignment: .top) {
                    Text(err).font(.system(size: 10)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer()
                    Button("Retry now", action: onReconnect).controlSize(.mini)
                }
            }
            probeView
            HStack(spacing: 6) {
                Button("Test connection") { model.test(host.alias) }
                    .disabled(model.probes[host.alias] == .running)
                Button("Install Navi…") { model.request(.install, for: host.alias) }
                if model.localPluginDir != nil {
                    Button("Install from this Mac…") { model.request(.offlineInstall, for: host.alias) }
                        .help("Copy this Mac's Navi plugin to ~/.navi/plugin on the host (no GitHub access needed)")
                }
                Button("Uninstall…") { model.request(.uninstall, for: host.alias) }
                Spacer()
                Button("Remove", role: .destructive, action: onRemove)
            }
            .controlSize(.small)
            .disabled(model.running.contains(host.alias))
            if model.running.contains(host.alias) {
                ProgressView().controlSize(.small)
            }
            ForEach(model.logs[host.alias] ?? []) { line in
                Label(line.text, systemImage: line.ok ? "checkmark.circle" : "xmark.octagon")
                    .font(.system(size: 10))
                    .foregroundStyle(line.ok ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var probeView: some View {
        switch model.probes[host.alias] {
        case .running?:
            Text("Testing…").font(.system(size: 10)).foregroundStyle(.secondary)
        case let .done(result)?:
            Text(result.summary).font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(result.problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
            }
        case let .failed(msg)?:
            Text(msg).font(.system(size: 10)).foregroundStyle(.red).textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }
}

/// Shows the exact commands before anything runs on the host.
private struct ConfirmCommandsSheet: View {
    let action: RemoteHostsModel.PendingAction
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(action.kind.rawValue) on \(action.alias)?").font(.headline)
            Text("Navi will run these commands, in order:")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(action.displayCommands.enumerated()), id: \.offset) { _, cmd in
                        Text(cmd)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }
            .frame(maxHeight: 220)
            if action.kind != .uninstall {
                Text("Hooks load at session start: restart Claude Code sessions already running on the host afterwards.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run", action: onRun).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500)
    }
}
