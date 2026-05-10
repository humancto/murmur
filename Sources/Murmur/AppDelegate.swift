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
