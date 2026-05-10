import AppKit
import KeyboardShortcuts
import MurmurCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "dev.murmur", category: "app")

    // Owned components.
    private let settingsStore = SettingsStore()
    private let capture = AudioCapture()
    private let transcriber = WhisperKitTranscriber()
    private let primaryInjector = AXInjectorAdapter()
    private let fallbackInjector = ClipboardInjectorAdapter()

    private var menuBar: MenuBarController!
    private var hud: HUDController!
    private var coordinator: DictationCoordinator!
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Murmur launching (\(MurmurInfo.version, privacy: .public))")

        let initialPromptProvider: @Sendable () -> String? = { [settingsStore] in
            let s = settingsStore.load()
            guard !s.vocabulary.isEmpty else { return nil }
            return s.vocabulary.joined(separator: ", ")
        }

        hud = HUDController()
        coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            primaryInjector: primaryInjector,
            fallbackInjector: fallbackInjector,
            hud: hud,
            initialPromptProvider: initialPromptProvider
        )
        settingsWindow = SettingsWindowController(store: settingsStore)
        menuBar = MenuBarController(
            onOpenSettings: { [weak self] in
                Task { @MainActor in self?.settingsWindow.showWindow() }
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        menuBar.install()

        // Hotkey wiring. Re-entrancy is enforced inside the coordinator.
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.handleKeyDown() }
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.handleKeyUp() }
        }

        // Bootstrap async work.
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        let settings = settingsStore.load()
        if !settings.didCompleteOnboarding {
            await Onboarding.run(settingsStore: settingsStore)
        }

        // Auto-open Settings whenever there's no usable hotkey binding.
        // Trigger covers two cases:
        //   1. First launch: onboarding ran, user may or may not have
        //      bound a key — Settings is where they finish if they didn't.
        //   2. Returning user with no binding (e.g., reset, upgraded
        //      from a build where the recorder didn't stick) — without
        //      Settings, they'd be stuck because the menu-bar icon may
        //      be hidden by the notch on 14"/16" MacBook Pros.
        // If a hotkey is already bound, we trust the user knows where
        // Settings lives and don't shove it at them on every launch.
        if KeyboardShortcuts.getShortcut(for: .dictate) == nil {
            settingsWindow.showWindow()
        }

        // Eager model warm-up so the first dictation isn't slow. Surface
        // the loading state on the menu bar; users can still bind a
        // hotkey while this runs.
        menuBar.setModelLoading(true)
        do {
            _ = try await transcriber.warmUp()
            menuBar.setModelLoading(false)
            log.info("Whisper model warmed up")
        } catch {
            menuBar.setModelLoading(false)
            log.error("Model warm-up failed: \(String(describing: error), privacy: .public)")
        }
    }

}
