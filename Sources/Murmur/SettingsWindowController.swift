import AppKit
import SwiftUI
import MurmurCore

/// Owns the single Settings window. The menu bar's "Settings…" entry
/// asks the controller to open it; subsequent invocations re-focus the
/// existing window rather than spawning duplicates.
///
/// We can't use SwiftUI's `Settings` scene (which would give us the
/// standard `Cmd+,` window for free) because Murmur uses AppKit
/// `@main` lifecycle, not SwiftUI App. Custom NSWindow + NSHostingView
/// is the equivalent shape and gives us full positioning control.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let store: SettingsStore
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func showWindow() {
        if let existing = window {
            // Defensive: if the user dragged the window onto a display
            // that's since been disconnected (laptop undocked), the
            // window will be ordered onto an off-screen frame. Re-center
            // before showing.
            let screensIntersect = NSScreen.screens.contains { $0.frame.intersects(existing.frame) }
            if !screensIntersect { existing.center() }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let initialSettings = store.load()
        let view = SettingsView(
            initial: initialSettings,
            onChange: { [weak self] updated in
                self?.persist(updated)
            }
        )

        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Murmur — Settings"
        win.contentView = host
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self

        // Add Auto Layout constraints so the SwiftUI content fills
        // the window bounds reliably regardless of resize.
        if let cv = win.contentView {
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                host.topAnchor.constraint(equalTo: cv.topAnchor),
                host.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
        }

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func persist(_ settings: MurmurCore.Settings) {
        do {
            try store.save(settings)
        } catch {
            // Persistence failure on a settings edit is recoverable —
            // the next save attempt will retry. Log and move on.
            NSLog("Murmur — settings save failed: \(error)")
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Hold the reference; reopening is faster if we don't tear down.
    }
}
