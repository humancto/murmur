import AppKit
import MurmurCore

@MainActor
final class MenuBarController {

    private let onBindHotkey: @Sendable () -> Void
    private let onQuit: @Sendable () -> Void
    private var item: NSStatusItem?
    private var modelLoading = false

    init(
        onBindHotkey: @escaping @Sendable () -> Void,
        onQuit: @escaping @Sendable () -> Void
    ) {
        self.onBindHotkey = onBindHotkey
        self.onQuit = onQuit
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = idleImage()
            button.image?.isTemplate = true
            button.toolTip = "Murmur — push-to-talk dictation"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Murmur \(MurmurInfo.version)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Bind hotkey…", action: #selector(bindHotkey)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Quit Murmur", action: #selector(quit), key: "q"))
        // The selectors target this controller via the NSMenuItem.target wiring done below.
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        self.item = item
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

    @objc private func bindHotkey() { onBindHotkey() }
    @objc private func quit() { onQuit() }
}
