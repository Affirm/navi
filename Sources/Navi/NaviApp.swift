import SwiftUI
import AppKit
import NaviCore

class NaviAppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NaviAppDelegate.isTerminating = true
    }
}

@main
struct NaviApp: App {
    @NSApplicationDelegateAdaptor(NaviAppDelegate.self) var appDelegate
    @StateObject private var monitor = EventMonitor()
    @StateObject private var floatingManager: FloatingWindowManager
    @StateObject private var enrichmentService: EnrichmentService
    @StateObject private var remoteBridge = RemoteBridge()
    private let menuBar = MenuBarManager()

    init() {
        let manager = FloatingWindowManager()
        _floatingManager = StateObject(wrappedValue: manager)
        _enrichmentService = StateObject(wrappedValue: EnrichmentService(floatingManager: manager))
    }

    var body: some Scene {
        Window("Navi", id: "monitor") {
            ContentView(monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService, isFloatingWindow: true)
                .onAppear {
                    monitor.attach(enrichmentService: enrichmentService)
                    enrichmentService.attach(monitor: monitor)
                    menuBar.attach(monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService)
                    if floatingManager.menuBarEnabled { menuBar.enable() }
                    remoteBridge.attach(sink: monitor)
                    monitor.remoteResponder = remoteBridge
                    configureRemoteHosts()
                }
                .onReceive(floatingManager.$remoteHostsEnabled) { _ in configureRemoteHosts() }
                .onReceive(floatingManager.$remoteHosts) { _ in configureRemoteHosts() }
                .onReceive(floatingManager.$sessionNamesEnabled) { _ in configureRemoteHosts() }
                .onReceive(floatingManager.$menuBarEnabled) { on in
                    if on { menuBar.enable() } else { menuBar.disable() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)
    }

    /// Start/stop relay connections to match settings. Called on the main
    /// thread from @Published `willSet`, so read the manager on the next turn
    /// to see the new values.
    private func configureRemoteHosts() {
        DispatchQueue.main.async { [floatingManager, remoteBridge] in
            remoteBridge.configure(
                hosts: floatingManager.remoteHostsEnabled ? floatingManager.remoteHosts : [],
                features: floatingManager.remoteRelayFeatures)
        }
    }
}
