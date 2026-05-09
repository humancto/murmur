@preconcurrency package import AppKit
private import Foundation
private import os
private import ApplicationServices

public enum AXInjectorResult: Sendable, Equatable {
    case inserted                              // AX path succeeded
    case unsupportedApp(bundleID: String?)     // not on the allowlist
    case noFocusedElement                      // no element has focus
    case axCallFailed                          // AX setter returned non-success
    case accessibilityNotGranted               // AX permission missing
}

/// Hard-coded allowlist of bundle IDs where `kAXSelectedTextAttribute`
/// setters reliably work in our manual testing on macOS 14.x.
///
/// Notes is **deliberately omitted** — it's WKWebView-backed since
/// macOS 10.13 and AX writes either silently no-op or strip formatting.
/// Don't add Safari either: the URL bar accepts AX writes but the page
/// DOM does not, and we can't reliably tell them apart without walking
/// element role; not worth the complexity for v0.1.
public let axInsertAllowlist: Set<String> = [
    "com.apple.TextEdit",
    "com.apple.mail",
    "com.apple.dt.Xcode",
    "com.apple.MobileSMS",
    "com.apple.Pages",
]

/// `@unchecked Sendable` wrapper for `AXUIElement`. AXUIElement is a
/// CoreFoundation type — thread-safe per CF rules for the read/write
/// API surface used here, but not annotated `Sendable` in the SDK.
/// Mirrors `PasteboardBox`'s rationale.
package final class AXUIElementBox: @unchecked Sendable {
    let element: AXUIElement
    package init(_ element: AXUIElement) { self.element = element }
}

/// Opportunistic AX-based text insertion. The `kAXSelectedTextAttribute`
/// setter REPLACES the current selection (or inserts at caret when
/// selection is empty, on the apps we ship in `axInsertAllowlist`).
/// Falls back to `ClipboardInjector` on any non-`.inserted` result.
public actor AXInjector {

    private nonisolated let frontmostApp: @Sendable () -> NSRunningApplication?
    private nonisolated let isAccessibilityTrusted: @Sendable () -> Bool
    private nonisolated let focusedElement: @Sendable (pid_t) -> AXUIElementBox?
    private nonisolated let setSelectedText: @Sendable (AXUIElement, String) -> Bool

    public init() {
        self.frontmostApp = AXInjector.realFrontmostApp
        self.isAccessibilityTrusted = AXInjector.realAccessibilityCheck
        self.focusedElement = AXInjector.realFocusedElement
        self.setSelectedText = AXInjector.realSetSelectedText
    }

    package init(
        frontmostApp: @escaping @Sendable () -> NSRunningApplication?,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool = { true },
        focusedElement: @escaping @Sendable (pid_t) -> AXUIElementBox?,
        setSelectedText: @escaping @Sendable (AXUIElement, String) -> Bool
    ) {
        self.frontmostApp = frontmostApp
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.focusedElement = focusedElement
        self.setSelectedText = setSelectedText
    }

    public func tryInsert(_ text: String) async -> AXInjectorResult {
        // AX permission gate — mirror ClipboardInjector. AX returns
        // .cannotComplete when untrusted, which we'd otherwise misdiagnose
        // as .noFocusedElement.
        if !isAccessibilityTrusted() {
            Self.log.debug("AX path skipped: accessibility not granted")
            return .accessibilityNotGranted
        }

        guard let app = frontmostApp() else {
            Self.log.debug("AX path skipped: no frontmost application")
            return .unsupportedApp(bundleID: nil)
        }
        let bundleID = app.bundleIdentifier
        guard let id = bundleID, axInsertAllowlist.contains(id) else {
            Self.log.debug("AX path skipped: \(bundleID ?? "nil", privacy: .public) not on allowlist")
            return .unsupportedApp(bundleID: bundleID)
        }
        guard let elemBox = focusedElement(app.processIdentifier) else {
            Self.log.debug("AX path skipped: no focused element in \(id, privacy: .public)")
            return .noFocusedElement
        }
        if setSelectedText(elemBox.element, text) {
            Self.log.debug("AX path inserted into \(id, privacy: .public)")
            return .inserted
        } else {
            Self.log.debug("AX path setter failed in \(id, privacy: .public)")
            return .axCallFailed
        }
    }

    // MARK: - Production defaults

    private static let log = Logger(subsystem: "dev.murmur", category: "ax")

    private static let realFrontmostApp: @Sendable () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    private static let realAccessibilityCheck: @Sendable () -> Bool = {
        AXIsProcessTrusted()
    }

    private static let realFocusedElement: @Sendable (pid_t) -> AXUIElementBox? = { pid in
        let appElement = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let focused else { return nil }
        // CFGetTypeID + as! is the standard pattern. unsafeBitCast skips
        // the type check; if Apple changes the returned alias type ever,
        // we'd hit UB. Defensive cast is cheap.
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return AXUIElementBox(focused as! AXUIElement)
    }

    private static let realSetSelectedText: @Sendable (AXUIElement, String) -> Bool = { element, text in
        // kAXSelectedTextAttribute REPLACES the current selection.
        // On an empty selection (caret only), the apps we allowlist
        // treat this as insert-at-caret. Apps that don't return non-
        // success here, and we fall through to ClipboardInjector.
        let err = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        return err == .success
    }
}
