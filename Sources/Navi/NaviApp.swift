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
                }
                .onReceive(floatingManager.$menuBarEnabled) { on in
                    if on { menuBar.enable() } else { menuBar.disable() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)
    }
}
