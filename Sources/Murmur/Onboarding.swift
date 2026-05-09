import AppKit
import AVFoundation
import ApplicationServices
import KeyboardShortcuts
import MurmurCore

/// First-run flow. Three sequential modals: microphone consent,
/// accessibility consent, hotkey binding. Sets
/// `Settings.didCompleteOnboarding = true` on success.
@MainActor
enum Onboarding {

    static func run(settingsStore: SettingsStore) async {
        // Step 1: microphone
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        if !mic {
            let alert = NSAlert()
            alert.messageText = "Microphone access denied"
            alert.informativeText = """
            Murmur needs the microphone to capture your dictation.
            Open System Settings → Privacy & Security → Microphone and
            enable Murmur, then relaunch.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")
            let r = alert.runModal()
            if r == .alertFirstButtonReturn {
                openMicrophoneSettings()
            }
            NSApplication.shared.terminate(nil)
            return
        }

        // Step 2: accessibility
        if !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = "Allow Murmur to type for you"
            alert.informativeText = """
            To paste your transcribed text into the focused app, Murmur \
            needs Accessibility permission.

            Click "Open System Settings" and enable Murmur in \
            Privacy & Security → Accessibility. Murmur will continue once \
            you've granted access.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Skip for now")
            let r = alert.runModal()
            if r == .alertFirstButtonReturn {
                // kAXTrustedCheckOptionPrompt is non-concurrency-safe in Swift 6;
                // use the literal CFString directly.
                let promptKey = "AXTrustedCheckOptionPrompt" as CFString
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
                openAccessibilitySettings()
                // Poll up to 60 seconds for the grant
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if AXIsProcessTrusted() { break }
                }
            }
        }

        // Step 3: hotkey binding
        let hotkeyAlert = NSAlert()
        hotkeyAlert.messageText = "Pick your dictation hotkey"
        hotkeyAlert.informativeText = """
        Hold this key combination to dictate. Release when you're done.

        Recommended: a function key (F13–F19) or a modifier-only chord \
        like ⌃⌥. Single keys like spacebar will conflict with normal typing.
        """
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .dictate)
        recorder.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        hotkeyAlert.accessoryView = recorder
        hotkeyAlert.addButton(withTitle: "Done")
        hotkeyAlert.runModal()

        // Mark onboarding done
        var settings = settingsStore.load()
        settings.didCompleteOnboarding = true
        try? settingsStore.save(settings)
    }

    private static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
