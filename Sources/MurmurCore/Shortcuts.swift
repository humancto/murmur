@preconcurrency public import KeyboardShortcuts

public extension KeyboardShortcuts.Name {

    /// Push-to-talk dictation hotkey.
    ///
    /// **No default binding shipped.** Per the KeyboardShortcuts README
    /// and apple-expert review: "do not set this for a publicly
    /// distributed app. Users find it annoying when random apps steal
    /// their existing keyboard shortcuts." Onboarding sets the binding
    /// on first run.
    ///
    /// Right-Cmd / Globe (fn) as default is a v1.1 feature requiring a
    /// custom `CGEventTap` for modifier-only press-and-hold detection;
    /// `KeyboardShortcuts` doesn't expose this directly.
    ///
    /// `nonisolated(unsafe)` is the documented Swift-6 escape hatch for
    /// the static-let-of-non-Sendable-type case. KeyboardShortcuts.Name
    /// is `Hashable` but not `Sendable`; it's effectively immutable
    /// (the name string and default-shortcut are set once at init), so
    /// the unsafe claim is sound by construction.
    nonisolated(unsafe) static let dictate = Self("dictate")
}
