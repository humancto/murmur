import AppKit
import MurmurCore

@MainActor
final class MenuBarController {

    private let onOpenSettings: @Sendable () -> Void
    private let onQuit: @Sendable () -> Void
    private var item: NSStatusItem?
    private var modelLoading = false

    init(
        onOpenSettings: @escaping @Sendable () -> Void,
        onQuit: @escaping @Sendable () -> Void
    ) {
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Icon-only on the menu bar. A text title is unnecessary visual
            // weight and on notch MacBook Pros it pushes the item into the
            // hidden overflow. The detailed name lives in the dropdown menu
            // and the tooltip.
            button.image = idleImage()
            button.image?.isTemplate = true
            button.toolTip = "Murmur — push-to-talk dictation · \(MurmurInfo.version)"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Murmur \(MurmurInfo.version)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Quit Murmur", action: #selector(quit), key: "q"))
        // The selectors target this controller via the NSMenuItem.target wiring done below.
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        self.item = item

        // Default-level log so users can confirm the bar item registered
        // even when filtering finds no `dev.murmur` Logger output (info-
        // level subsystem logs are restricted by default in macOS 13+).
        NSLog("Murmur: status item installed — look in your menu bar for 'Murmur' next to the mic icon")
    }

    func setModelLoading(_ loading: Bool) {
        modelLoading = loading
        guard let item, let button = item.button else { return }
        button.image = loading ? loadingImage() : idleImage()
        button.image?.isTemplate = true
        button.toolTip = loading
            ? "Murmur — loading transcription model…"
            : "Murmur — push-to-talk dictation"
    }

    // MARK: - Icons

    private func idleImage() -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")?
            .withSymbolConfiguration(cfg)
            ?? NSImage()
    }

    private func loadingImage() -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: "mic.badge.ellipsis", accessibilityDescription: "Loading model")?
            .withSymbolConfiguration(cfg)
            ?? NSImage()
    }

    private func menuItem(title: String, action: Selector, key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    // MARK: - Actions

    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}
