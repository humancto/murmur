# Plan — `clipboard-injection`

**Roadmap item:** `- [ ] clipboard-injection` (item 6, milestone v0.1).

**Goal:** Type Murmur's transcribed text into whatever app the user is in, via `NSPasteboard` + a synthesized `Cmd+V`. This is the **primary** injection path per architecture-plan §9.1 — works in 95%+ of macOS apps including all Electron, web, and Terminal.

## What ships

```
Sources/MurmurCore/
└── ClipboardInjector.swift          (new — actor; save → set → ⌘V → restore)

Tests/MurmurCoreTests/
└── ClipboardInjectorTests.swift     (new — pasteboard isolation + secure-input gate)
```

No new dependencies — `AppKit.NSPasteboard` and `CoreGraphics.CGEvent` are SDK-built-in.

## Design

```swift
@preconcurrency public import AppKit
private import Foundation
private import os

public enum ClipboardInjectorResult: Sendable, Equatable {
    case injected
    case secureInputBlocked      // IsSecureEventInputEnabled() was true
    case emptyText               // caller passed ""
}

public enum ClipboardInjectorError: Error, Sendable {
    case keyDownEventCreationFailed
    case keyUpEventCreationFailed
}

public actor ClipboardInjector {

    /// Pasteboard to write to. `.general` in production; tests inject a
    /// custom-named pasteboard so they don't touch the user's clipboard.
    private let pasteboard: NSPasteboard

    /// Hook for tests: returns true if the OS reports secure event input
    /// is active (sudo prompt, password field, iTerm2 secure mode).
    /// Production uses `IsSecureEventInputEnabled` from HIToolbox.
    private let isSecureInputActive: @Sendable () -> Bool

    /// Hook for tests: posts the synthesized ⌘V keystroke. Production
    /// uses `CGEvent`. Tests stub this out so the test runner doesn't
    /// receive a real ⌘V.
    private let postKeystroke: @Sendable () throws -> Void

    public init(
        pasteboard: NSPasteboard = .general,
        isSecureInputActive: @escaping @Sendable () -> Bool = ClipboardInjector.defaultSecureInputCheck,
        postKeystroke: @escaping @Sendable () throws -> Void = ClipboardInjector.defaultPostKeystroke
    ) {
        self.pasteboard = pasteboard
        self.isSecureInputActive = isSecureInputActive
        self.postKeystroke = postKeystroke
    }

    /// Save current pasteboard, set new text, post ⌘V, schedule restore.
    /// Refuses when secure input is active — paste keystrokes get
    /// silently dropped by the OS in that mode, and we never want to
    /// route password-field text through the LLM cleanup pass anyway.
    @discardableResult
    public func inject(_ text: String) async throws -> ClipboardInjectorResult {
        guard !text.isEmpty else { return .emptyText }

        if isSecureInputActive() {
            Self.log.info("Injection refused: secure event input active")
            return .secureInputBlocked
        }

        // Save prior contents so we can restore them. Best-effort —
        // pasteboard contents can be huge or non-string; we save string
        // form only because that's what we'll restore in v0.1. v0.5 can
        // do the full multi-type save/restore.
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try postKeystroke()

        // Restore after a 500 ms delay — long enough that the receiving
        // app has consumed the paste, short enough that the user doesn't
        // hit ⌘V again and get the wrong text. Architecture-plan §9.1.
        Task.detached { [pasteboard] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await ClipboardInjector.restore(pasteboard: pasteboard, to: previous)
        }
        return .injected
    }

    private static func restore(pasteboard: NSPasteboard, to previous: String?) async {
        pasteboard.clearContents()
        if let previous {
            pasteboard.setString(previous, forType: .string)
        }
    }

    // MARK: - Defaults

    private static let log = Logger(subsystem: "dev.murmur", category: "clipboard")

    public static let defaultSecureInputCheck: @Sendable () -> Bool = {
        // IsSecureEventInputEnabled is in HIToolbox, available since 10.4.
        // Stable but private; the documented use case is exactly this.
        IsSecureEventInputEnabled()
    }

    public static let defaultPostKeystroke: @Sendable () throws -> Void = {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ClipboardInjectorError.keyDownEventCreationFailed
        }
        let kVK_ANSI_V: CGKeyCode = 0x09
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false)
        else {
            throw ClipboardInjectorError.keyDownEventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
```

### Why an actor

Restore and inject can race if the user holds the hotkey twice in quick succession; actor isolation serializes the save/set/restore pair so the second restore can't fire mid-second-injection. Also future-proofs for v2 features (cancellation tokens, in-flight tracking).

### Why `@preconcurrency public import AppKit`

`NSPasteboard` is the public-API parameter (callers might want to pass a custom pasteboard). AppKit isn't fully `Sendable`-annotated in Swift 6.

### Test strategy

The tests can't actually post `Cmd+V` to the test runner without breaking the test runner. So the `postKeystroke` and `isSecureInputActive` hooks are injected. Tests verify:

1. Empty text returns `.emptyText` without touching the pasteboard
2. Normal injection writes to a test pasteboard, calls the keystroke hook, and (eventually) restores
3. Secure input blocked returns `.secureInputBlocked`, doesn't touch the pasteboard, doesn't call the keystroke hook
4. Restore restores the previous pasteboard content
5. Empty previous content restores to empty

## Tests

```swift
import AppKit
import Testing
import MurmurCore

@Suite("ClipboardInjector")
struct ClipboardInjectorTests {

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("murmur-tests-\(UUID().uuidString)"))
    }

    @Test("empty text returns .emptyText, no pasteboard write")
    func emptyTextNoOp() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let injector = ClipboardInjector(pasteboard: pb,
                                          isSecureInputActive: { false },
                                          postKeystroke: {})
        let result = try await injector.inject("")
        #expect(result == .emptyText)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("secure input active returns .secureInputBlocked, no pasteboard write")
    func secureInputBlocked() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        nonisolated(unsafe) var keystrokePosted = false
        let injector = ClipboardInjector(
            pasteboard: pb,
            isSecureInputActive: { true },
            postKeystroke: { keystrokePosted = true }
        )
        let result = try await injector.inject("hello")
        #expect(result == .secureInputBlocked)
        #expect(keystrokePosted == false)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("normal injection writes text and posts keystroke")
    func normalInjection() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        nonisolated(unsafe) var keystrokePosted = false
        let injector = ClipboardInjector(
            pasteboard: pb,
            isSecureInputActive: { false },
            postKeystroke: { keystrokePosted = true }
        )
        let result = try await injector.inject("hello world")
        #expect(result == .injected)
        // Pasteboard now holds the injected text (until restore fires).
        #expect(pb.string(forType: .string) == "hello world")
        #expect(keystrokePosted == true)
    }

    @Test("pasteboard is restored after the delay")
    func pasteboardRestoresAfterDelay() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let injector = ClipboardInjector(pasteboard: pb,
                                          isSecureInputActive: { false },
                                          postKeystroke: {})
        _ = try await injector.inject("hello")
        // Wait for the restore (default delay is 500 ms; allow margin).
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("restore handles empty prior pasteboard")
    func emptyPriorRestores() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        let injector = ClipboardInjector(pasteboard: pb,
                                          isSecureInputActive: { false },
                                          postKeystroke: {})
        _ = try await injector.inject("hello")
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(pb.string(forType: .string) == nil || pb.string(forType: .string)?.isEmpty == true)
    }
}
```

## Acceptance criteria

- [ ] `Sources/MurmurCore/ClipboardInjector.swift` exists with the actor + result/error types + production defaults
- [ ] `Tests/MurmurCoreTests/ClipboardInjectorTests.swift` — 5 swift-testing tests
- [ ] `swift build` clean, no warnings
- [ ] `swift test` exits 0 with **37** tests passing (32 prior + 5 new)
- [ ] Tests do not affect the user's real clipboard (per-test named pasteboards)
- [ ] Branch: `feat/clipboard-injection`

## Risks

- **`IsSecureEventInputEnabled` is private API.** Documented since 10.4, used by every keyboard tool on the App Store. Apple-expert pre-approved this in §9.2.
- **`CGEvent.post(tap: .cghidEventTap)` requires accessibility permission.** First-run UI flow lives in a later item; here, if the OS rejects the post, tests still pass (they stub the keystroke), and production users see the macOS accessibility permission prompt.
- **Restore Task.detached** continues even if the actor is deallocated. That's fine — `pasteboard` is captured by value. No leak.
- **The 500 ms restore delay is hand-tuned.** Some heavy-load apps may not consume the paste in 500 ms. Tunable later via a config knob; default is the architecture-plan recommendation.

## Open questions for apple-expert (tight)

1. **`actor` vs `struct`/`class`** — actor for serialization. Worth it or premature?
2. **`postKeystroke` and `isSecureInputActive` injection** — clean for testability, but the hooks are public (so tests outside this module could pass them too). Should they be `internal`-only via `package` visibility?
3. **`CGEvent.post(tap: .cghidEventTap)` vs `.cgSessionEventTap`** — HID-level reaches secure input contexts but is blocked by the secure-input check anyway. `.cgSessionEventTap` would route through the WindowServer; might play better with some apps. Recommend?
4. **Restore delay** — 500 ms hard-coded. Make it configurable now or wait for an actual report?
