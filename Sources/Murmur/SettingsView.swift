import SwiftUI
import KeyboardShortcuts
import MurmurCore

/// Settings UI bound to a `MurmurCore.Settings` value type (qualified
/// to disambiguate from SwiftUI's own `Settings` scene). Calls
/// `onChange` on every mutation; the controller persists to UserDefaults.
///
/// Note (apple-expert PR #5 carry-over): we deliberately don't use
/// `@AppStorage` because it's only `RawRepresentable`/primitive, not
/// arbitrary `Codable`. `@State` + `onChange` is the idiomatic shape
/// for whole-struct settings.
struct SettingsView: View {

    @State private var settings: MurmurCore.Settings
    private let onChange: (MurmurCore.Settings) -> Void

    init(initial: MurmurCore.Settings, onChange: @escaping (MurmurCore.Settings) -> Void) {
        self._settings = State(initialValue: initial)
        self.onChange = onChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                header

                hotkeySection
                Divider()

                vocabularySection
                Divider()

                cleanupSection
                Divider()

                captureSection
                Divider()

                cuesSection
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 540)
        .background(Color(NSColor.windowBackgroundColor))
        // Single source of truth for persistence: any field flip on the
        // whole `Settings` struct emits to onChange. Removed the earlier
        // per-field .onChange modifiers — those were per-field bookkeeping
        // that was easy to forget for new fields and silently lose saves.
        // (apple-expert PR #10 review)
        .onChange(of: settings) { _, newValue in
            onChange(newValue)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 22, weight: .semibold))
            Text("Murmur \(MurmurInfo.version) · all changes save automatically · stays on your Mac")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeySection: some View {
        // Note: `KeyboardShortcuts.Recorder` writes directly to its own
        // UserDefaults keys; rebinds intentionally bypass our `onChange`
        // since the library owns hotkey persistence end-to-end.
        section(title: "Hotkey", subtitle: "Hold this combination to dictate. Release when you're done.") {
            KeyboardShortcuts.Recorder(for: .dictate)
                .frame(maxWidth: 240, alignment: .leading)
        }
    }

    private var vocabularySection: some View {
        section(
            title: "Personal vocabulary",
            subtitle: "One term per line. Names, jargon, technical terms. Passed to Whisper as context — bigger accuracy gain on these terms than any model upgrade."
        ) {
            TextEditor(text: vocabularyText)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
    }

    private var cleanupSection: some View {
        section(
            title: "Cleanup pass",
            subtitle: "Run a small local language model over the transcription to fix punctuation and remove disfluencies. Your voice is preserved — the model is constrained not to rephrase."
        ) {
            Toggle(isOn: $settings.llmCleanupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable cleanup pass")
                        .font(.system(size: 13, weight: .medium))
                    Text(settings.llmCleanupEnabled ? "Active when the cleanup model is downloaded." : "Off — Whisper output goes through verbatim.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var captureSection: some View {
        section(
            title: "Maximum capture duration",
            subtitle: "Hard cap per utterance. Hold the hotkey beyond this and capture stops, returning what was recorded so far."
        ) {
            HStack(spacing: 12) {
                Slider(
                    value: $settings.captureMaxDurationSec,
                    in: 10...120,
                    step: 5
                )
                .frame(maxWidth: 320)

                Text("\(Int(settings.captureMaxDurationSec)) s")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var cuesSection: some View {
        section(
            title: "Audio cues",
            subtitle: "Subtle tick on capture start, tock on capture stop."
        ) {
            Toggle("Play audio cues", isOn: $settings.playAudioCues)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Helpers

    private var vocabularyText: Binding<String> {
        Binding(
            get: { settings.vocabulary.joined(separator: "\n") },
            set: { newValue in
                settings.vocabulary = newValue
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }
}
