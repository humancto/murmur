import AppKit
import Foundation
import Testing
import MurmurCore

@Suite("ClipboardInjector")
struct ClipboardInjectorTests {

    /// Per-test isolated NSPasteboard. Named pasteboards are isolated
    /// from `.general` and from each other.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("murmur-tests-\(UUID().uuidString)"))
    }

    @Test("empty text returns .emptyText, no pasteboard write")
    func emptyTextNoOp() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let injector = ClipboardInjector(
            pasteboard: PasteboardBox(pb),
            isSecureInputActive: { false },
            postKeystroke: {}
        )
        let result = try await injector.inject("")
        #expect(result == .emptyText)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("secure input blocks injection, no keystroke posted, pasteboard untouched")
    func secureInputBlocked() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let posted = KeystrokeFlag()
        let injector = ClipboardInjector(
            pasteboard: PasteboardBox(pb),
            isSecureInputActive: { true },
            postKeystroke: { posted.fire() }
        )
        let result = try await injector.inject("hello")
        #expect(result == .secureInputBlocked)
        #expect(posted.didFire == false)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("accessibility-not-trusted blocks injection")
    func accessibilityNotGrantedBlocks() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let posted = KeystrokeFlag()
        let injector = ClipboardInjector(
            pasteboard: PasteboardBox(pb),
            isSecureInputActive: { false },
            isAccessibilityTrusted: { false },
            postKeystroke: { posted.fire() }
        )
        let result = try await injector.inject("hello")
        #expect(result == .accessibilityNotGranted)
        #expect(posted.didFire == false)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("normal injection writes text and posts keystroke")
    func normalInjection() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let posted = KeystrokeFlag()
        let injector = ClipboardInjector(
            pasteboard: PasteboardBox(pb),
            isSecureInputActive: { false },
            isAccessibilityTrusted: { true },
            postKeystroke: { posted.fire() }
        )
        let result = try await injector.inject("hello world")
        #expect(result == .injected)
        // Pasteboard now holds the injected text (until restore fires).
        #expect(pb.string(forType: .string) == "hello world")
        #expect(posted.didFire == true)
    }

    @Test("pasteboard is restored after the delay")
    func pasteboardRestoresAfterDelay() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let injector = ClipboardInjector(
            pasteboard: PasteboardBox(pb),
            isSecureInputActive: { false },
            postKeystroke: {}
        )
        _ = try await injector.inject("hello")
        // Wait past the 500 ms restore delay
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("re-entrant injection cancels the prior pending restore")
    func reentrantInjectCancelsPendingRestore() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let injector = ClipboardInjector(
            pasteboard: PasteboardBox(pb),
            isSecureInputActive: { false },
            postKeystroke: {}
        )

        _ = try await injector.inject("first")
        // Fire a second inject inside the 500 ms window of the first restore.
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await injector.inject("second")

        // At t=350ms the first restore would have fired (clobbering "second")
        // if we hadn't cancelled it. With cancellation, "second" sticks.
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(pb.string(forType: .string) == "second")

        // After the second restore (now t≈350+500 = 850ms past second-inject), prior is back.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(pb.string(forType: .string) == "before")
    }
}

/// Simple thread-safe one-shot flag for asserting the keystroke hook
/// fired. Reference type so we can capture-and-mutate from the test
/// closure without escaping `var` capture rules.
private final class KeystrokeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return _fired
    }

    func fire() {
        lock.lock(); defer { lock.unlock() }
        _fired = true
    }
}
