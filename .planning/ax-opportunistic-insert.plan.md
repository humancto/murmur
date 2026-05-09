# Plan — `ax-opportunistic-insert`

**Roadmap item:** item 7/10. Optimization layer over the clipboard path: when the focused app is a known native AppKit text field, use `AXUIElement` to insert directly (no clipboard pollution, no ⌘V synthesis). Falls back to `ClipboardInjector` on any failure.

## What ships

```
Sources/MurmurCore/
└── AXInjector.swift        (new — actor; allowlist-gated AXUIElement insertion)

Tests/MurmurCoreTests/
└── AXInjectorTests.swift   (new — allowlist routing, no real AX touched)
```

## Design

```swift
@preconcurrency package import AppKit
private import Foundation
private import os
private import ApplicationServices

public enum AXInjectorResult: Sendable, Equatable {
    case inserted                      // AX path succeeded
    case unsupportedApp(bundleID: String?)   // not on the allowlist
    case noFocusedElement              // no element has focus
    case axCallFailed                  // AX setter returned non-success
}

/// Hard-coded allowlist of bundle IDs where `kAXSelectedTextAttribute`
/// setters reliably work. Native AppKit text views; not Electron, not
/// web inputs, not Terminal. apple-expert-approved set.
public let axInsertAllowlist: Set<String> = [
    "com.apple.TextEdit",
    "com.apple.Notes",
    "com.apple.mail",
    "com.apple.dt.Xcode",
    "com.apple.MobileSMS",
    "com.apple.Pages",
    "com.apple.iWork.Pages",
]

public actor AXInjector {

    private nonisolated let frontmostApp: @Sendable () -> NSRunningApplication?
    private nonisolated let focusedElement: @Sendable (pid_t) -> AXUIElementBox?
    private nonisolated let setSelectedText: @Sendable (AXUIElement, String) -> Bool

    public init() {
        self.frontmostApp = AXInjector.realFrontmostApp
        self.focusedElement = AXInjector.realFocusedElement
        self.setSelectedText = AXInjector.realSetSelectedText
    }

    package init(
        frontmostApp: @escaping @Sendable () -> NSRunningApplication?,
        focusedElement: @escaping @Sendable (pid_t) -> AXUIElementBox?,
        setSelectedText: @escaping @Sendable (AXUIElement, String) -> Bool
    ) {
        self.frontmostApp = frontmostApp
        self.focusedElement = focusedElement
        self.setSelectedText = setSelectedText
    }

    public func tryInsert(_ text: String) async -> AXInjectorResult {
        guard let app = frontmostApp() else { return .unsupportedApp(bundleID: nil) }
        let bundleID = app.bundleIdentifier
        guard let id = bundleID, axInsertAllowlist.contains(id) else {
            return .unsupportedApp(bundleID: bundleID)
        }
        guard let elemBox = focusedElement(app.processIdentifier) else {
            return .noFocusedElement
        }
        if setSelectedText(elemBox.element, text) {
            return .inserted
        } else {
            return .axCallFailed
        }
    }

    // MARK: - Production defaults

    private static let log = Logger(subsystem: "dev.murmur", category: "ax")

    private static let realFrontmostApp: @Sendable () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    private static let realFocusedElement: @Sendable (pid_t) -> AXUIElementBox? = { pid in
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        return AXUIElementBox(unsafeBitCast(element, to: AXUIElement.self))
    }

    private static let realSetSelectedText: @Sendable (AXUIElement, String) -> Bool = { element, text in
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return err == .success
    }
}

/// `@unchecked Sendable` wrapper for `AXUIElement` (CFType, not Sendable).
/// Used in the package init for tests.
package final class AXUIElementBox: @unchecked Sendable {
    let element: AXUIElement
    package init(_ element: AXUIElement) { self.element = element }
}
```

### Tests (5)

1. `unsupportedApp returns .unsupportedApp` — frontmost is "com.example.unknown"
2. `nil bundleID returns .unsupportedApp(nil)` — frontmost has no bundleID
3. `allowlisted app + focused element + setter true → .inserted`
4. `allowlisted app + no focused element → .noFocusedElement`
5. `allowlisted app + setter returns false → .axCallFailed`

All hooks injected; no real AX or NSWorkspace touched.

## Acceptance

- 5 new tests (43 total)
- swift build clean, tests pass
- Branch `feat/ax-opportunistic-insert`
