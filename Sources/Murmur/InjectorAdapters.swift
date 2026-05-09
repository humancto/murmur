import MurmurCore

/// `TextInjecting` adapter for `AXInjector`. Returns `true` when the AX
/// path actually inserted; false signals "try the fallback" to the
/// coordinator.
struct AXInjectorAdapter: TextInjecting {
    let injector = AXInjector()

    func insert(_ text: String) async throws -> Bool {
        let result = await injector.tryInsert(text)
        switch result {
        case .inserted: return true
        case .unsupportedApp, .noFocusedElement, .axCallFailed, .accessibilityNotGranted:
            return false
        }
    }
}

/// `TextInjecting` adapter for `ClipboardInjector`. Returns `true` only
/// on `.injected`; `.secureInputBlocked` / `.accessibilityNotGranted` /
/// `.emptyText` translate to false (no further fallback exists in v0.1).
struct ClipboardInjectorAdapter: TextInjecting {
    let injector = ClipboardInjector()

    func insert(_ text: String) async throws -> Bool {
        let result = try await injector.inject(text)
        switch result {
        case .injected: return true
        case .secureInputBlocked, .accessibilityNotGranted, .emptyText:
            return false
        }
    }
}
