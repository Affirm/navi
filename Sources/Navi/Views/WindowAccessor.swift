import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    var floatingManager: FloatingWindowManager? = nil

    class Coordinator: NSObject {
        var floatingManager: FloatingWindowManager?
        @objc func windowWillClose(_ notification: Notification) {
            guard !NaviAppDelegate.isTerminating else { return }
            DispatchQueue.main.async { self.floatingManager?.isFloating = false }
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.floatingManager = floatingManager
        return c
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            NaviWindow.ref = window
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // Minimum window size at the AppKit level. The content frame also
            // enforces minWidth: 360 so these match. The dynamic "don't shrink
            // while events exist" rule in resizeWindow handles the transient
            // jitter window — this minSize is just the floor the user can drag.
            window.minSize = NSSize(width: 360, height: 200)
            // Restore saved position, or default to top-right corner
            if !window.setFrameAutosaveName("NaviWindow") {
                // Name already set — frame restored automatically
            }
            // If the autosaved frame is below the new minimum, grow it.
            if window.frame.width < 360 {
                var frame = window.frame
                frame.size.width = 360
                window.setFrame(frame, display: true)
            }
            if UserDefaults.standard.string(forKey: "NSWindow Frame NaviWindow") == nil,
               let screen = window.screen {
                let sf = screen.visibleFrame
                let x = sf.maxX - window.frame.width - 20
                let y = sf.maxY - window.frame.height - 20
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            // Hide if floating mode is off
            if !UserDefaults.standard.bool(forKey: "NaviFloatingWindow") {
                window.orderOut(nil)
            }
            // Sync isFloating when user closes the window via traffic light
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            // When the user finishes a live (drag) resize, remember that size
            // as a floor so auto-shrink doesn't take the window back below it.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { note in
                guard let win = note.object as? NSWindow else { return }
                UserDefaults.standard.set(Double(win.frame.width), forKey: "NaviUserMinWidth")
                UserDefaults.standard.set(Double(win.frame.height), forKey: "NaviUserMinHeight")
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
