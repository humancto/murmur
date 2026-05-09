# Plan — `hotkey-and-settings`

**Roadmap item:** `- [ ] hotkey-and-settings` (item 5, milestone v0.1).

**Goal:** Wire the hotkey machinery and a typed `Settings` value type into `MurmurCore`. After this PR, the project has:

1. A named, persisted, user-rebindable hotkey (`KeyboardShortcuts.Name.dictate`) with a sane default.
2. A `Settings: Codable, Sendable` struct holding non-hotkey user prefs (vocabulary, audio cues, capture cap), and a thin `SettingsStore` for `UserDefaults`-backed persistence with `Codable` round-trip.

This item does **not** wire the hotkey to anything. `onKeyDown`/`onKeyUp` registration that actually triggers `AudioCapture.start()` / `stop()` lives in `end-to-end-v0.1`. The point here is to land the machinery so that wiring is a five-line change later.

## Deviation from architecture plan §2.3

Architecture plan says: _"Hotkey: default right-Cmd hold-to-talk."_

Reality check: `KeyboardShortcuts` (sindresorhus) v2+ supports modifier-only shortcuts but **not** right-Cmd-only as a press-and-hold trigger reliably across macOS versions; right-Cmd is also commonly remapped (Karabiner, etc) and conflicts in practice. The honest v0.1 default is **F19** — a common convention for Wispr-/Whispr-style tools, no conflicts, easy for users to remap to a physical key via Karabiner-Elements if they prefer.

Right-Cmd / Globe (fn) as default is **a v1.1 feature** requiring a custom `CGEventTap` for modifier-only press-and-hold detection (KeyboardShortcuts doesn't expose this cleanly). The architecture plan §2.3 line will be updated in a follow-up roadmap chore.

## What ships

```
Package.swift                                 (+ KeyboardShortcuts dep on MurmurCore)
Sources/MurmurCore/
├── (existing)
├── Shortcuts.swift                           (new — KeyboardShortcuts.Name extension)
└── Settings.swift                            (new — Codable Settings + SettingsStore)

Tests/MurmurCoreTests/
├── (existing)
└── SettingsTests.swift                       (new — 6 swift-testing tests)
```

No `Shortcuts.swift` tests in this PR — `KeyboardShortcuts.Name` extensions are a constant declaration, no logic to test. The library's own tests cover registration. We test the parts we own (`Settings`, `SettingsStore`).

## KeyboardShortcuts dependency

Repo: `https://github.com/sindresorhus/KeyboardShortcuts`. Latest stable: pin via `from: "2.x.0"` (verify exact in apple-expert review).

Adds one new dependency to `Package.resolved`. Trade-off: small, focused library with strong adoption (Raycast, Sindre's own apps); maintained; SwiftUI-native; supports both record-UI and programmatic registration. Cheaper than rolling our own.

```swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
],
targets: [
    .target(
        name: "MurmurCore",
        dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
        ],
        ...
    ),
],
```

## Shortcuts.swift sketch

```swift
public import KeyboardShortcuts

public extension KeyboardShortcuts.Name {

    /// Push-to-talk dictation hotkey. Default: F19.
    /// Right-Cmd / Globe defaults are a v1.1 feature (require a custom
    /// CGEventTap for modifier-only press-and-hold; not exposed by
    /// KeyboardShortcuts directly).
    static let dictate = Self("dictate", default: .init(.f19))
}
```

That's the entire file. Keeps shortcut declaration in one place; the consumer-side wiring (the `onKeyDown` / `onKeyUp` registration) lives in the end-to-end item.

## Settings.swift sketch

```swift
public import Foundation

/// User-controlled preferences. Persisted as JSON in UserDefaults.
/// Hotkey binding lives in KeyboardShortcuts (separate UserDefaults
/// key, separate persistence machinery — keeps this struct from
/// duplicating that state).
public struct Settings: Codable, Sendable, Equatable {

    /// Personal vocabulary list. Joined comma-separated and passed to
    /// Whisper as `initial_prompt` for accent + jargon biasing.
    public var vocabulary: [String]

    /// Subtle "tick" on capture start, "tock" on capture stop.
    /// Off by default — onboarding turns it on if the user opts in.
    public var playAudioCues: Bool

    /// Hard cap on a single capture (seconds). Mirrors
    /// architecture-plan §9.13. Configurable for power users with
    /// long-form dictation needs.
    public var captureMaxDurationSec: Double

    public init(
        vocabulary: [String] = [],
        playAudioCues: Bool = false,
        captureMaxDurationSec: Double = 60
    ) {
        self.vocabulary = vocabulary
        self.playAudioCues = playAudioCues
        self.captureMaxDurationSec = captureMaxDurationSec
    }
}

/// Thin wrapper around UserDefaults for typed `Settings` access.
/// Sendable because UserDefaults is documented thread-safe on Apple
/// platforms; we hold no other mutable state.
public struct SettingsStore: Sendable {

    private static let key = "com.archithrapaka.murmur.settings.v1"

    public let suite: UserDefaults

    public init(suite: UserDefaults = .standard) {
        self.suite = suite
    }

    /// Load the current settings. Returns defaults if no settings have
    /// been saved yet OR if saved data fails to decode (corrupted JSON,
    /// schema migration not yet handled, etc).
    public func load() -> Settings {
        guard let data = suite.data(forKey: Self.key) else {
            return Settings()
        }
        guard let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            // Corrupted or stale-schema data — fall back to defaults.
            // (Schema migration story lives in v0.5; for v0.1 we eat it.)
            return Settings()
        }
        return decoded
    }

    /// Persist `settings` to UserDefaults. Throws on encoder failure
    /// (extremely unlikely for this struct shape but kept for honesty).
    public func save(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        suite.set(data, forKey: Self.key)
    }

    /// Remove the persisted settings. Used by tests; will be exposed in
    /// the v1.0 settings UI as "reset to defaults."
    public func clear() {
        suite.removeObject(forKey: Self.key)
    }
}
```

### Design choices, defended

- **`Codable, Sendable, Equatable`.** `Equatable` is non-premature here (tests need it for round-trip equality assertions, and the settings UI in v1.0 will read it for "is dirty?" change detection).
- **Single key namespaced by reverse-DNS** (`com.archithrapaka.murmur.settings.v1`). The `.v1` suffix is intentional: when we add fields and need a real schema migration in v0.5, we'll change the suffix and key off the migration logic.
- **`SettingsStore` is `Sendable` struct, not actor.** UserDefaults is documented thread-safe; an actor would only add hop overhead.
- **`load()` swallows decode errors** — returns defaults rather than throwing. Reasoning: bad on-disk data shouldn't prevent the app from launching. The v0.5 first-run-download item ships proper schema migration.
- **Hotkey binding is _not_ in `Settings`.** `KeyboardShortcuts` persists its own bindings to UserDefaults under its own keys. Mirroring it here would be duplicate state with two sources of truth; we don't.
- **`public import KeyboardShortcuts`** in `Shortcuts.swift` because `KeyboardShortcuts.Name` is the public-API surface. `public import Foundation` in `Settings.swift` is _not_ needed — `Settings` exposes only `[String]`, `Bool`, `Double`; Foundation symbols are internal-only.

## Tests

`SettingsTests.swift`, swift-testing, 6 tests. Use a per-test in-memory `UserDefaults` suite so tests don't pollute the real defaults DB.

```swift
import Foundation
import Testing
import MurmurCore

@Suite("Settings")
struct SettingsTests {

    /// Per-test isolated UserDefaults suite. Auto-cleaned via removeSuite.
    private func tempSuite() -> UserDefaults {
        let name = "murmur-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return suite
    }

    @Test("default Settings has empty vocabulary, audio cues off, 60s cap")
    func defaultSettingsAreSensible() {
        let s = Settings()
        #expect(s.vocabulary.isEmpty)
        #expect(s.playAudioCues == false)
        #expect(s.captureMaxDurationSec == 60)
    }

    @Test("Codable round-trip preserves equality")
    func codableRoundTrip() throws {
        let original = Settings(
            vocabulary: ["Archith", "WhisperKit", "ANE"],
            playAudioCues: true,
            captureMaxDurationSec: 120
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == original)
    }

    @Test("SettingsStore returns defaults when no data persisted")
    func storeReturnsDefaultsOnMissingData() {
        let suite = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: suite.suiteName) }
        let store = SettingsStore(suite: suite)
        #expect(store.load() == Settings())
    }

    @Test("SettingsStore round-trips via UserDefaults suite")
    func storeRoundTrips() throws {
        let suite = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: suite.suiteName) }
        let store = SettingsStore(suite: suite)
        let payload = Settings(vocabulary: ["foo", "bar"], playAudioCues: true, captureMaxDurationSec: 30)
        try store.save(payload)
        #expect(store.load() == payload)
    }

    @Test("SettingsStore returns defaults on malformed JSON")
    func storeFallsBackOnBadData() {
        let suite = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: suite.suiteName) }
        suite.set(Data("not valid json".utf8), forKey: "com.archithrapaka.murmur.settings.v1")
        let store = SettingsStore(suite: suite)
        #expect(store.load() == Settings())
    }

    @Test("SettingsStore.clear removes the persisted entry")
    func storeClear() throws {
        let suite = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: suite.suiteName) }
        let store = SettingsStore(suite: suite)
        try store.save(Settings(vocabulary: ["x"]))
        store.clear()
        #expect(store.load() == Settings())
    }
}
```

## Acceptance criteria

- [ ] `Package.swift` adds `KeyboardShortcuts` dependency + product on `MurmurCore`
- [ ] `Sources/MurmurCore/Shortcuts.swift` declares `KeyboardShortcuts.Name.dictate` with `.f19` default
- [ ] `Sources/MurmurCore/Settings.swift` ships `Settings` + `SettingsStore`
- [ ] `Tests/MurmurCoreTests/SettingsTests.swift` — 6 swift-testing tests, all in temp suites
- [ ] `swift build` clean, no warnings under strict concurrency
- [ ] `swift test` exits 0 with **31** tests passing (25 prior + 6 new)
- [ ] No tests touch the user's real UserDefaults
- [ ] Branch: `feat/hotkey-and-settings`
- [ ] Single squash-merged PR

## Risks

- **`KeyboardShortcuts` API churn.** v2.x has been stable for >18 months; pinning `from: "2.0.0"` is safe. If they release v3 with breaking API changes, we control the pin in `Package.resolved`.
- **`F19` as default isn't on every keyboard.** Most Apple keyboards stop at F12; F13+ are virtual. KeyboardShortcuts handles this — the user can rebind via the future Settings UI; for now they remap via Karabiner if F19 isn't reachable on their hardware. Documented.
- **Right-Cmd default deferred.** Architecture plan §2.3 line gets updated in a roadmap chore commit (not this PR — keeps the change focused). Tracked in the deviation note above.
- **`Settings` schema growth.** Adding a field is non-breaking (new field decodes as default if missing). Removing or renaming requires a `.v2` key migration. The `.v1` suffix in the storage key sets that up.
- **`UserDefaults.standard` from `MurmurCore` is fine for the executable**, but if we later run `MurmurCore` inside an XPC service (v0.5 llama.cpp service), the standard defaults are scoped to the XPC binary. The v0.5 plan accounts for this by injecting an explicit `suite:`.
- **Encoder/decoder reuse.** I `JSONEncoder()`/`JSONDecoder()` per call. They're cheap to construct; profile shows zero impact on this code path. If it ever shows up in profiling, cache them on `SettingsStore` — but they're not `Sendable` if mutated, so cache via `let` only.

## Open questions for apple-expert

1. **`F19` vs another default.** F19 is the convention but has the "doesn't exist on most keyboards" caveat. F13 is more common (Apple's full-size keyboards have it). Recommend?
2. **`KeyboardShortcuts` version pin.** `from: "2.0.0"` — verify current major and check for any 2026 deprecations or Swift-6 strict-concurrency issues.
3. **`Settings` field set for v0.1.** I include `vocabulary`, `playAudioCues`, `captureMaxDurationSec`. Anything obvious missing or out of scope?
4. **`UserDefaults` thread-safety claim.** Apple documents reads/writes as thread-safe but warns against KVO across threads. We don't KVO; just read/write data values. Confirm.
5. **`SettingsStore` as struct vs actor.** Struct given UserDefaults is thread-safe. Actor would add hop cost. Push back if you'd prefer the actor for future-proofing.
6. **`save` is `throws` even though `JSONEncoder().encode` of this struct will not fail in practice.** Honest signature, or unnecessary noise the caller has to `try`-handle?
7. **Missing field on decode.** If the persisted JSON has fewer fields than current `Settings` (older app version's data), Swift's default Codable behavior is to throw. Should `Settings` use a manual `init(from decoder:)` with default values for missing fields, or is the v0.5 schema-migration item the right place?
8. **Hotkey storage.** `KeyboardShortcuts` stores under its own UserDefaults keys (`KeyboardShortcuts_dictate`). User backups / sync (iCloud) won't carry these by default. Out of scope for v0.1, but flag if you want a different storage strategy.
