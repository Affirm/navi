import SwiftUI
import AppKit
import NaviCore

private struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shared ref so ContentView can resize the window directly.
class NaviWindow {
    static var ref: NSWindow?
}

let autoLaunchFlagPath = "/tmp/navi/no-auto-launch"

struct ContentView: View {
    @ObservedObject var monitor: EventMonitor
    @ObservedObject var floatingManager: FloatingWindowManager
    @ObservedObject var enrichmentService: EnrichmentService
    var isFloatingWindow: Bool = false
    @State private var autoLaunch: Bool = !FileManager.default.fileExists(atPath: "/tmp/navi/no-auto-launch")
    @State private var permissionSoundOn: Bool = UserDefaults.standard.object(forKey: "NaviSound.permission") as? Bool ?? true
    @State private var permissionSound: String = UserDefaults.standard.string(forKey: "NaviSound.permission.name") ?? "Glass"
    @State private var stopSoundOn: Bool = UserDefaults.standard.object(forKey: "NaviSound.stop") as? Bool ?? false
    @State private var stopSound: String = UserDefaults.standard.string(forKey: "NaviSound.stop.name") ?? "Glass"
    @State private var notificationSoundOn: Bool = UserDefaults.standard.object(forKey: "NaviSound.notification") as? Bool ?? false
    @State private var notificationSound: String = UserDefaults.standard.string(forKey: "NaviSound.notification.name") ?? "Glass"
    @State private var infoSoundOn: Bool = UserDefaults.standard.object(forKey: "NaviSound.info") as? Bool ?? false
    @State private var infoSound: String = UserDefaults.standard.string(forKey: "NaviSound.info.name") ?? "Glass"
    @AppStorage("NaviFontScale") private var fontScale: Double = 1.0
    @State private var showSettings = false

    private static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private var sessionGroups: [SessionGroup] {
        let eventsBySession = Dictionary(grouping: monitor.events) { $0.sessionID }
        return monitor.sessions.values.map { info in
            SessionGroup(
                id: info.id,
                info: info,
                events: eventsBySession[info.id] ?? []
            )
        }
        .sorted { a, b in
            // Pending first, then by recency
            if a.hasPending != b.hasPending { return a.hasPending }
            return a.info.lastActivity > b.info.lastActivity
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                controlsBar
                if monitor.needsBinaryRestart {
                    binaryRestartBanner
                }
                if floatingManager.showSessionRestartHint {
                    sessionRestartHint
                }
                Divider()
                if monitor.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .frame(minWidth: 360, idealWidth: 360, maxWidth: .infinity)
            .overlay(
                Group {
                    if isFloatingWindow {
                        GeometryReader { geo in
                            Color.clear.preference(key: ViewHeightKey.self, value: geo.size.height)
                        }
                    }
                }
            )

            Spacer(minLength: 0)
        }
        .onPreferenceChange(ViewHeightKey.self) { height in
            if isFloatingWindow { resizeWindow(to: height + 28) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(Group { if isFloatingWindow { WindowAccessor(floatingManager: floatingManager) } })
    }

    // Auto-resize respects two floors:
    //   1. The user's last drag (so a user-widened window doesn't shrink back).
    //   2. The current window height, while any events are in the monitor.
    //      This blocks the shrink that races with popover dismissal / section
    //      auto-collapse, which is where the visual jitter comes from. Once all
    //      events clear (monitor.events is empty), the window shrinks freely
    //      back to the baseline.
    private func resizeWindow(to targetHeight: CGFloat) {
        DispatchQueue.main.async {
            guard let window = NaviWindow.ref else { return }
            if targetHeight < 1 { return }
            let userMinW = CGFloat(UserDefaults.standard.double(forKey: "NaviUserMinWidth"))
            let userMinH = CGFloat(UserDefaults.standard.double(forKey: "NaviUserMinHeight"))
            let currentH = window.frame.height
            let targetW = max(360, userMinW)
            var targetH = max(targetHeight, userMinH)
            if !self.monitor.events.isEmpty && targetH < currentH {
                targetH = currentH
            }
            let top = window.frame.maxY
            var frame = window.frame
            frame.size.height = targetH
            frame.size.width = targetW
            frame.origin.y = top - targetH
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16))
            Text("Navi")
                .font(.system(size: 14, weight: .semibold))
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                settingsPopover
            }
            // Pop the floating window back out without diving into Settings.
            // Shown from the menu-bar popover (not the window itself): reopens
            // the window when it's closed, and otherwise brings it to the front
            // when it's open but buried behind other windows.
            if !isFloatingWindow {
                Button {
                    if !floatingManager.isFloating {
                        floatingManager.isFloating = true   // reopen (didSet orders it front)
                    }
                    NaviWindow.ref?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show floating window / bring to front")
            }
            Spacer()
            if !sessionGroups.isEmpty {
                Text("\(sessionGroups.count) session\(sessionGroups.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if !monitor.events.isEmpty {
                Button {
                    monitor.clearAll()
                } label: {
                    Text("Clear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @State private var settingsTab = 0
    private let naviVersion = naviCurrentVersion

    private var settingsPopover: some View {
        VStack(spacing: 0) {
            Picker("", selection: $settingsTab) {
                Text("General").tag(0)
                Text("Experimental").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if settingsTab == 0 {
                generalTab
            } else {
                experimentalTab
            }

            Divider()
                .padding(.horizontal, 12)

            Text("Navi v\(naviVersion)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Text("Thanks for using Navi! #ask-navi\nFeedback and feature suggestions are welcome!")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(width: 280)
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $autoLaunch) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-launch Navi")
                            .font(.system(size: 11))
                        Text("Automatically launch Navi when Claude triggers a hook event")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.blue)
                .onChange(of: autoLaunch) { _, on in
                    if on {
                        try? FileManager.default.removeItem(atPath: autoLaunchFlagPath)
                    } else {
                        FileManager.default.createFile(atPath: autoLaunchFlagPath, contents: nil)
                    }
                }

                Divider()

                Text("Interface")
                    .font(.system(size: 11, weight: .semibold))

                settingsRow("Menu bar icon", subtitle: "Adds a menu bar icon for Navi.",
                    isOn: Binding(get: { floatingManager.menuBarEnabled }, set: { floatingManager.menuBarEnabled = $0 }))
                if floatingManager.menuBarEnabled {
                    settingsRow("Floating window", subtitle: "Always-on-top floating window.",
                        isOn: Binding(get: { floatingManager.isFloating }, set: { floatingManager.isFloating = $0 }), indent: true)
                }
                settingsRow("Session names", subtitle: "Show the session name (from /rename) instead of the project folder.",
                    isOn: Binding(get: { floatingManager.sessionNamesEnabled }, set: { floatingManager.sessionNamesEnabled = $0 }))
                settingsRow("Permission details", subtitle: "Show a \"Show details\" button on permission requests with the full tool input.",
                    isOn: Binding(get: { floatingManager.permissionDetailsEnabled }, set: { floatingManager.permissionDetailsEnabled = $0 }))

                Divider()

                Text("Session row")
                    .font(.system(size: 11, weight: .semibold))

                settingsRow("Folder path", subtitle: "Show the working directory for each session.",
                    isOn: Binding(get: { floatingManager.showFolderEnabled }, set: { floatingManager.showFolderEnabled = $0 }))
                settingsRow("Git status", subtitle: "Show branch, dirty state, ahead/behind counts, and open PR.",
                    isOn: Binding(get: { floatingManager.showGitEnabled }, set: { floatingManager.showGitEnabled = $0 }))
                settingsRow("Claude mode", subtitle: "Show the active permission mode (plan, auto, acceptEdits, bypassPermissions).",
                    isOn: Binding(get: { floatingManager.showModeEnabled }, set: { floatingManager.showModeEnabled = $0 }))
                settingsRow("Claude model", subtitle: "Show the model used by each session.",
                    isOn: Binding(get: { floatingManager.showModelEnabled }, set: { floatingManager.showModelEnabled = $0 }))

                Divider()

                Text("Sounds")
                    .font(.system(size: 11, weight: .semibold))

                soundRow("Permission", isOn: $permissionSoundOn, sound: $permissionSound, key: "permission")
                soundRow("Finished", isOn: $stopSoundOn, sound: $stopSound, key: "stop")
                soundRow("Notification", isOn: $notificationSoundOn, sound: $notificationSound, key: "notification")
                soundRow("Info", isOn: $infoSoundOn, sound: $infoSound, key: "info")

                Divider()

                Text("Display")
                    .font(.system(size: 11, weight: .semibold))

                HStack(spacing: 6) {
                    Text("A")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: $fontScale, in: 0.8...1.4, step: 0.1)
                        .controlSize(.mini)
                    Text("A")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit Navi")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var contextAlertThresholdPicker: some View {
        let t1 = Binding<String>(
            get: { floatingManager.contextAlertThreshold1 == 0 ? "0" : "\(floatingManager.contextAlertThreshold1 / 1000)" },
            set: { if let v = Int($0.trimmingCharacters(in: .whitespaces)), v >= 0 { floatingManager.contextAlertThreshold1 = v * 1000 } }
        )
        let t2 = Binding<String>(
            get: { floatingManager.contextAlertThreshold2 == 0 ? "0" : "\(floatingManager.contextAlertThreshold2 / 1000)" },
            set: { if let v = Int($0.trimmingCharacters(in: .whitespaces)), v >= 0 { floatingManager.contextAlertThreshold2 = v * 1000 } }
        )
        return VStack(alignment: .leading, spacing: 4) {
            thresholdRow(label: "Warning", color: .orange, binding: t1)
            thresholdRow(label: "Critical", color: .red, binding: t2)
            Text("Enter K tokens (e.g. 200 = 200K). Set to 0 to disable.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
        .padding(.vertical, 2)
    }

    private func thresholdRow(label: String, color: Color, binding: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TextField("0", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
            Text("K")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsRow(_ title: String, subtitle: String, isOn: Binding<Bool>, indent: Bool = false, requiresRestart: Bool = false, requiresSessionRestart: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if requiresSessionRestart {
                    Label("Restart Claude sessions to apply", systemImage: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle("", isOn: requiresRestart ? Binding(
                get: { isOn.wrappedValue },
                set: { newValue in
                    isOn.wrappedValue = newValue
                    floatingManager.pendingRestart = true
                }
            ) : isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.blue)
                .labelsHidden()
        }
        .padding(.leading, indent ? 12 : 0)
    }

    private var experimentalTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These features may not have been fully tested, especially together. Results may be unexpected.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            settingsRow("Sub-agents", subtitle: "Show sub-agents (Task tool) as a tree nested under the parent session that spawned them.",
                isOn: Binding(get: { floatingManager.showSubagentsEnabled }, set: { floatingManager.showSubagentsEnabled = $0 }))

            settingsRow("Context size", subtitle: "Show a mini bar indicating context window usage (teal → yellow → orange → red at 150K/200K/400K tokens).",
                isOn: Binding(get: { floatingManager.showContextEnabled }, set: { floatingManager.showContextEnabled = $0 }))

            settingsRow("Context window alerts",
                subtitle: "Notify when a session crosses the configured thresholds, recommending /compact or a new session.",
                isOn: Binding(get: { floatingManager.contextAlertsEnabled }, set: { floatingManager.contextAlertsEnabled = $0 }))

            if floatingManager.contextAlertsEnabled {
                contextAlertThresholdPicker
            }

            Spacer()
        }
        .padding(12)
    }

    private var restartBanner: some View {
        VStack(spacing: 6) {
            Divider()
            Text("Restart required for changes to take effect")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Button {
                FloatingWindowManager.relaunch()
            } label: {
                Text("Restart Navi")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var binaryRestartBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
            Text("Navi was rebuilt")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                FloatingWindowManager.relaunch()
            } label: {
                Text("Restart")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.05))
    }

    private var sessionRestartHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text("Navi updated — restart Claude sessions for new features")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                floatingManager.showSessionRestartHint = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.05))
    }

    private func soundRow(_ label: String, isOn: Binding<Bool>, sound: Binding<String>, key: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 75, alignment: .leading)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.blue)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { _, on in
                    UserDefaults.standard.set(on, forKey: "NaviSound.\(key)")
                }
            Menu(isOn.wrappedValue ? sound.wrappedValue : "—") {
                ForEach(Self.systemSounds, id: \.self) { s in
                    Button(s) {
                        sound.wrappedValue = s
                        UserDefaults.standard.set(s, forKey: "NaviSound.\(key).name")
                        NSSound(named: NSSound.Name(s))?.play()
                    }
                }
            }
            .font(.system(size: 11))
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!isOn.wrappedValue)
            .opacity(isOn.wrappedValue ? 1 : 0.4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Listening for events...")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    private var sessionList: some View {
        VStack(spacing: 6) {
            ForEach(sessionGroups) { group in
                SessionSection(group: group, monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService)
            }
        }
        .padding(.vertical, 6)
    }
}
