import SwiftUI
import AppKit
import NaviCore

class MenuBarManager: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var monitor: EventMonitor?
    private var floatingManager: FloatingWindowManager?
    private var enrichmentService: EnrichmentService?
    private var eventObserver: Any?

    func attach(monitor: EventMonitor, floatingManager: FloatingWindowManager, enrichmentService: EnrichmentService) {
        self.monitor = monitor
        self.floatingManager = floatingManager
        self.enrichmentService = enrichmentService
    }

    func enable() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(pendingCount: 0)
        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        // Observe event changes to update icon
        eventObserver = NotificationCenter.default.addObserver(
            forName: .init("NaviEventsChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let count = note.userInfo?["pendingCount"] as? Int ?? 0
            self?.updateIcon(pendingCount: count)
        }
    }

    func disable() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover?.close()
        popover = nil
        if let obs = eventObserver {
            NotificationCenter.default.removeObserver(obs)
            eventObserver = nil
        }
    }

    private func updateIcon(pendingCount: Int) {
        guard let button = statusItem?.button else { return }
        let name = pendingCount > 0 ? "bolt.circle.fill" : "bolt.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Navi")
        image?.isTemplate = true
        button.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let monitor = monitor,
              let floatingManager = floatingManager,
              let enrichmentService = enrichmentService else { return }
        // Reuse existing popover, create once
        if popover == nil {
            let pop = NSPopover()
            pop.contentSize = NSSize(width: floatingManager.popoverWidth, height: 500)
            pop.behavior = .transient
            pop.animates = true
            pop.contentViewController = NSHostingController(
                rootView: ContentView(monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService)
            )
            popover = pop
        } else {
            // Width may have changed since the popover was first created (toggles
            // flipped in Settings). Re-apply before showing so the change takes
            // effect without a relaunch.
            popover?.contentSize = NSSize(width: floatingManager.popoverWidth, height: popover?.contentSize.height ?? 500)
        }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
