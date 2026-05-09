// `package import` so the `package`-scoped customizing init can take
// NSPasteboard as a parameter (tests live in the same package). We
// don't `public import` AppKit — we don't want to re-export it.
@preconcurrency package import AppKit
private import Foundation
private import os
private import ApplicationServices  // AXIsProcessTrusted
private import Carbon.HIToolbox     // IsSecureEventInputEnabled

public enum ClipboardInjectorResult: Sendable, Equatable {
    case injected
    case secureInputBlocked         // IsSecureEventInputEnabled() was true
    case accessibilityNotGranted    // AX permission not granted; primary inject path is dead
    case emptyText                  // caller passed ""
}

public enum ClipboardInjectorError: Error, Sendable {
    case keyDownEventCreationFailed
    case keyUpEventCreationFailed
}

/// `@unchecked Sendable` wrapper for `NSPasteboard` (which isn't
/// `Sendable` in the SDK). NSPasteboard is documented thread-safe for
/// the read/write API surface we use; this box makes the type-system
/// claim explicit. Used by `ClipboardInjector`'s `package` init.
package final class PasteboardBox: @unchecked Sendable {
    let pasteboard: NSPasteboard
    package init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
}

/// Save the current clipboard, set Murmur's transcribed text, post a
/// synthesized ⌘V, then restore the prior contents 500 ms later.
/// Primary injection path per architecture-plan §9.1.
///
/// The restore is owned by the actor as a tracked `Task`. A second
/// `inject(_:)` call before the restore fires cancels the pending
/// restore — otherwise the first restore would clobber the second
/// injection's pasteboard (the actual reason for being an actor).
///
/// Tests substitute the secure-input / accessibility / keystroke hooks
/// via the `package` init so the test runner doesn't actually receive
/// a synthesized ⌘V.
public actor ClipboardInjector {

    private nonisolated let pasteboard: NSPasteboard
    private nonisolated let isSecureInputActive: @Sendable () -> Bool
    private nonisolated let isAccessibilityTrusted: @Sendable () -> Bool
    private nonisolated let postKeystroke: @Sendable () throws -> Void

    private var pendingRestore: Task<Void, Never>? = nil

    /// Snapshot of the user's clipboard captured at the start of an
    /// injection chain. Re-entrant `inject(_:)` calls within the 500 ms
    /// restore window do NOT overwrite this — otherwise the restore
    /// would write back our own previous injection rather than the
    /// user's actual clipboard. Cleared after a successful restore.
    private var userSnapshot: String? = nil
    private var userSnapshotValid: Bool = false

    /// Production initializer. Uses `.general` pasteboard, real
    /// `IsSecureEventInputEnabled`, real `AXIsProcessTrusted`, and a
    /// real `CGEvent`-based ⌘V keystroke.
    public init() {
        self.pasteboard = .general
        self.isSecureInputActive = ClipboardInjector.realSecureInputCheck
        self.isAccessibilityTrusted = ClipboardInjector.realAccessibilityCheck
        self.postKeystroke = ClipboardInjector.realPostKeystroke
    }

    /// Test/customization initializer. `package` scope keeps the hooks
    /// out of the public API — third-party callers can't accidentally
    /// pass a forged secure-input check.
    ///
    /// `NSPasteboard` is not `Sendable` in the SDK, so tests pass a
    /// `PasteboardBox` (`@unchecked Sendable`) — `NSPasteboard` is
    /// documented thread-safe for read/write at the API level we use.
    package init(
        pasteboard: PasteboardBox,
        isSecureInputActive: @escaping @Sendable () -> Bool,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool = { true },
        postKeystroke: @escaping @Sendable () throws -> Void
    ) {
        self.pasteboard = pasteboard.pasteboard
        self.isSecureInputActive = isSecureInputActive
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.postKeystroke = postKeystroke
    }

    @discardableResult
    public func inject(_ text: String) async throws -> ClipboardInjectorResult {
        guard !text.isEmpty else { return .emptyText }

        if isSecureInputActive() {
            Self.log.info("Injection refused: secure event input active")
            return .secureInputBlocked
        }
        if !isAccessibilityTrusted() {
            Self.log.info("Injection refused: accessibility permission not granted")
            return .accessibilityNotGranted
        }

        // Cancel any in-flight restore from a previous inject — otherwise
        // its 500 ms-delayed clobber would land mid-second-injection.
        pendingRestore?.cancel()
        pendingRestore = nil

        // Snapshot the user's clipboard only on the first inject of a
        // chain. Re-entrant injects within the 500 ms restore window
        // would otherwise capture our own previous injection.
        // TODO(v0.5): multi-type save/restore. v0.1 captures .string only.
        if !userSnapshotValid {
            userSnapshot = pasteboard.string(forType: .string)
            userSnapshotValid = true
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try postKeystroke()

        // Tracked task owned by the actor so re-entry can cancel it.
        pendingRestore = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await self?.performRestore()
        }
        return .injected
    }

    private func performRestore() {
        pasteboard.clearContents()
        if let snapshot = userSnapshot {
            pasteboard.setString(snapshot, forType: .string)
        }
        userSnapshot = nil
        userSnapshotValid = false
        pendingRestore = nil
    }

    // MARK: - Production defaults

    private static let log = Logger(subsystem: "dev.murmur", category: "clipboard")

    /// `IsSecureEventInputEnabled` is public Carbon HIToolbox API since
    /// macOS 10.4 — used by every keyboard tool on the App Store. Not
    /// SPI; documented in `Carbon.HIToolbox.Events`.
    private static let realSecureInputCheck: @Sendable () -> Bool = {
        IsSecureEventInputEnabled()
    }

    private static let realAccessibilityCheck: @Sendable () -> Bool = {
        AXIsProcessTrusted()
    }

    private static let realPostKeystroke: @Sendable () throws -> Void = {
        // `.hidSystemState` paired with `.cghidEventTap` is the right
        // combo for HID-level posting. `.combinedSessionState` is for
        // *reading* state, not posting; mismatched source states cause
        // some apps (Citrix, RDP, certain Electron builds) to drop ⌘V.
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ClipboardInjectorError.keyDownEventCreationFailed
        }
        let kVK_ANSI_V: CGKeyCode = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true) else {
            throw ClipboardInjectorError.keyDownEventCreationFailed
        }
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false) else {
            throw ClipboardInjectorError.keyUpEventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
