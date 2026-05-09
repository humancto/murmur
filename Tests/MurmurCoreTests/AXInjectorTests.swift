import AppKit
import Foundation
import Testing
import MurmurCore
import ApplicationServices

@Suite("AXInjector")
struct AXInjectorTests {

    /// Build a stub `NSRunningApplication`-shaped function. We can't
    /// construct a real one without launching a process, so the tests
    /// sidestep `NSRunningApplication` and inject `nil` for the
    /// "no frontmost" / "no bundleID" cases, and use a minimal subclass
    /// for the allowlist tests via the bundleIdentifier override.
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
        private let _bundleID: String?
        private let _pid: pid_t
        init(bundleID: String?, pid: pid_t = 12345) {
            self._bundleID = bundleID
            self._pid = pid
            super.init()
        }
        override var bundleIdentifier: String? { _bundleID }
        override var processIdentifier: pid_t { _pid }
    }

    private func dummyAXBox() -> AXUIElementBox {
        // Any AXUIElement works for the "passed-through to setter" tests
        // because the setter hook is a closure that ignores the element.
        // System-wide is reliably constructible without permissions.
        AXUIElementBox(AXUIElementCreateSystemWide())
    }

    @Test("accessibility not granted short-circuits with .accessibilityNotGranted")
    func accessibilityGateBlocks() async {
        let injector = AXInjector(
            frontmostApp: { FakeApp(bundleID: "com.apple.TextEdit") },
            isAccessibilityTrusted: { false },
            focusedElement: { _ in nil },
            setSelectedText: { _, _ in true }
        )
        let result = await injector.tryInsert("hello")
        #expect(result == .accessibilityNotGranted)
    }

    @Test("unsupported app returns .unsupportedApp with the bundleID")
    func unsupportedApp() async {
        let injector = AXInjector(
            frontmostApp: { FakeApp(bundleID: "com.example.notreal") },
            focusedElement: { _ in nil },
            setSelectedText: { _, _ in true }
        )
        let result = await injector.tryInsert("hello")
        #expect(result == .unsupportedApp(bundleID: "com.example.notreal"))
    }

    @Test("nil bundleID returns .unsupportedApp(nil)")
    func nilBundleID() async {
        let injector = AXInjector(
            frontmostApp: { FakeApp(bundleID: nil) },
            focusedElement: { _ in nil },
            setSelectedText: { _, _ in true }
        )
        let result = await injector.tryInsert("hello")
        #expect(result == .unsupportedApp(bundleID: nil))
    }

    @Test("allowlisted app with no focused element returns .noFocusedElement")
    func noFocusedElement() async {
        let injector = AXInjector(
            frontmostApp: { FakeApp(bundleID: "com.apple.TextEdit") },
            focusedElement: { _ in nil },
            setSelectedText: { _, _ in true }
        )
        let result = await injector.tryInsert("hello")
        #expect(result == .noFocusedElement)
    }

    @Test("allowlisted app with focused element and successful setter returns .inserted")
    func successfulInsert() async {
        let captured = CapturedText()
        let injector = AXInjector(
            frontmostApp: { FakeApp(bundleID: "com.apple.TextEdit") },
            focusedElement: { _ in AXInjectorTests().dummyAXBox() },
            setSelectedText: { _, text in
                captured.set(text)
                return true
            }
        )
        let result = await injector.tryInsert("hello world")
        #expect(result == .inserted)
        #expect(captured.value == "hello world")
    }

    @Test("setter returning false yields .axCallFailed (caller falls back to clipboard)")
    func setterFailureBubblesUp() async {
        let injector = AXInjector(
            frontmostApp: { FakeApp(bundleID: "com.apple.TextEdit") },
            focusedElement: { _ in AXInjectorTests().dummyAXBox() },
            setSelectedText: { _, _ in false }
        )
        let result = await injector.tryInsert("hello")
        #expect(result == .axCallFailed)
    }
}

/// Thread-safe captured-text holder for the successful-insert test.
private final class CapturedText: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String = ""
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        _value = s
    }
}
