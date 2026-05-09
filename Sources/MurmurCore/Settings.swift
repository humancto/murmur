// User-controlled preferences persisted as JSON in UserDefaults.
//
// Hotkey bindings live separately, in `KeyboardShortcuts`'s own
// UserDefaults keys — keeps that state from being duplicated here.
//
// SwiftUI binding shape: do NOT reach for `@AppStorage`. It only works
// with primitives / `RawRepresentable`, not arbitrary `Codable`. The
// settings UI binds via `@State var settings: Settings` plus
// `onChange { try? store.save($0) }`.

// `public import Foundation` because `SettingsStore.suite: UserDefaults`
// is public — UserDefaults must be re-exported under InternalImportsByDefault.
public import Foundation
private import os

public struct Settings: Codable, Sendable, Equatable {

    /// Personal vocabulary list. Joined comma-separated and passed to
    /// Whisper as `initial_prompt` for accent + jargon biasing.
    public var vocabulary: [String]

    /// Subtle "tick" on capture start, "tock" on capture stop.
    /// Off by default; onboarding turns it on if the user opts in.
    public var playAudioCues: Bool

    /// Hard cap on a single capture (seconds). Mirrors
    /// architecture-plan §9.13. Configurable for power users with
    /// long-form dictation needs.
    public var captureMaxDurationSec: Double

    /// Whether the user has completed first-run onboarding (mic +
    /// accessibility + hotkey binding). Persisted so subsequent launches
    /// skip the modal flow.
    public var didCompleteOnboarding: Bool

    public init(
        vocabulary: [String] = [],
        playAudioCues: Bool = false,
        captureMaxDurationSec: Double = 60,
        didCompleteOnboarding: Bool = false
    ) {
        self.vocabulary = vocabulary
        self.playAudioCues = playAudioCues
        self.captureMaxDurationSec = captureMaxDurationSec
        self.didCompleteOnboarding = didCompleteOnboarding
    }

    // Manual decoding so a Settings JSON written by an older app build
    // (with fewer fields) decodes successfully against this newer struct
    // — every missing field falls back to its default.
    private enum CodingKeys: String, CodingKey {
        case vocabulary, playAudioCues, captureMaxDurationSec, didCompleteOnboarding
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        self.vocabulary = (try c.decodeIfPresent([String].self, forKey: .vocabulary)) ?? defaults.vocabulary
        self.playAudioCues = (try c.decodeIfPresent(Bool.self, forKey: .playAudioCues)) ?? defaults.playAudioCues
        self.captureMaxDurationSec = (try c.decodeIfPresent(Double.self, forKey: .captureMaxDurationSec)) ?? defaults.captureMaxDurationSec
        self.didCompleteOnboarding = (try c.decodeIfPresent(Bool.self, forKey: .didCompleteOnboarding)) ?? defaults.didCompleteOnboarding
    }
}

/// Thin UserDefaults-backed persistence for `Settings`.
///
/// `@unchecked Sendable` because `UserDefaults` is documented
/// thread-safe on Apple platforms (atomic per-key reads/writes), but
/// the SDK type isn't annotated `Sendable` in Swift 6. We hold no
/// other mutable state.
public struct SettingsStore: @unchecked Sendable {

    /// Storage key. The `.v1` suffix lets us land an explicit migration
    /// to `.v2` later if the schema changes incompatibly. Forward-compat
    /// field additions don't need a migration — `Settings.init(from:)`
    /// handles missing fields with defaults.
    private static let key = "dev.murmur.settings.v1"

    private static let log = Logger(subsystem: "dev.murmur", category: "settings")

    public let suite: UserDefaults

    public init(suite: UserDefaults = .standard) {
        self.suite = suite
    }

    /// Load the current settings. Returns defaults if no settings have
    /// been saved yet OR if saved data fails to decode (logged at
    /// `.error` so silent recovery is observable in Console.app).
    public func load() -> Settings {
        guard let data = suite.data(forKey: Self.key) else {
            return Settings()
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            Self.log.error("Settings decode failed; falling back to defaults: \(String(describing: error), privacy: .public)")
            return Settings()
        }
    }

    /// Persist `settings` to UserDefaults. Throws on encoder failure.
    /// Encoder failure for this struct shape is essentially impossible,
    /// but the signature is honest: `JSONEncoder().encode` is `throws`,
    /// rebadging it as `try?` would be silent error swallowing.
    public func save(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        suite.set(data, forKey: Self.key)
    }

    /// Remove the persisted settings. Used by tests; the v1.0 settings
    /// UI exposes this as "reset to defaults."
    public func clear() {
        suite.removeObject(forKey: Self.key)
        Self.log.info("Settings cleared")
    }
}
