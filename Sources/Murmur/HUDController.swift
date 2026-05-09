import AppKit
import MurmurCore
import SwiftUI

/// Thin floating HUD. Renders a translucent pill near the active screen's
/// center-bottom showing recording / processing / error states.
///
/// Conforms to `DictationHUDPresenting` so the (actor-isolated)
/// coordinator can drive it from any context — `update(state:)` hops
/// to the main actor internally.
@MainActor
final class HUDController: NSObject, DictationHUDPresenting {

    private var window: NSPanel?
    private let viewState = HUDViewState()

    func update(state: DictationState) async {
        await MainActor.run { self.applyState(state) }
    }

    private func applyState(_ state: DictationState) {
        viewState.state = state
        switch state {
        case .idle:
            hide()
        case .recording, .processing:
            show()
        case .error:
            show()
            // Auto-hide errors after a short window
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if case .error = self.viewState.state { self.hide() }
            }
        }
    }

    private func show() {
        let win = window ?? makeWindow()
        position(win)
        win.orderFrontRegardless()
        window = win
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: HUDView(state: viewState)
                .frame(width: 240, height: 72)
        )
        return panel
    }

    /// Position on the screen containing the mouse pointer
    /// (apple-expert: `NSScreen.main` is wrong on clamshell setups).
    private func position(_ win: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let panelSize = win.frame.size
        let x = frame.midX - panelSize.width / 2
        let y = frame.minY + 80
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observable model the SwiftUI view binds to.
@MainActor
final class HUDViewState: ObservableObject {
    @Published var state: DictationState = .idle
}
