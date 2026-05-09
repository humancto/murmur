private import Foundation
private import os

/// Lifecycle states the HUD layer reflects. Pure value type, crosses
/// the actor boundary cleanly.
public enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

/// Anything that wants to render dictation state. The Murmur executable
/// implements this with an `NSPanel` HUD; tests pass a stub.
public protocol DictationHUDPresenting: AnyObject, Sendable {
    func update(state: DictationState) async
}

/// Anything that wants to inject text into the focused field. Production
/// uses `AXInjector` first then `ClipboardInjector`; tests inject stubs.
public protocol TextInjecting: Sendable {
    /// Returns true if the text was inserted. False means caller should
    /// try the fallback path.
    func insert(_ text: String) async throws -> Bool
}

/// Glues the dictation pipeline together: hotkey → mic → trim →
/// transcribe → inject. Lives in `MurmurCore` so it's fully testable
/// without AppKit.
///
/// Re-entrancy: the coordinator tracks an internal state machine and
/// rejects `keyDown` events while already recording or processing.
/// apple-expert called this out — the user can mash the hotkey and we
/// must not start a second capture before the first completes.
public actor DictationCoordinator {

    private let capture: AudioCapture
    private let vad: VAD
    private let transcriber: any Transcribing
    private let primaryInjector: any TextInjecting
    private let fallbackInjector: any TextInjecting
    private weak var hud: (any DictationHUDPresenting)?

    private var state: DictationState = .idle
    private var initialPromptProvider: @Sendable () -> String?

    public init(
        capture: AudioCapture,
        vad: VAD = VAD(),
        transcriber: any Transcribing,
        primaryInjector: any TextInjecting,
        fallbackInjector: any TextInjecting,
        hud: (any DictationHUDPresenting)?,
        initialPromptProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.capture = capture
        self.vad = vad
        self.transcriber = transcriber
        self.primaryInjector = primaryInjector
        self.fallbackInjector = fallbackInjector
        self.hud = hud
        self.initialPromptProvider = initialPromptProvider
    }

    public var currentState: DictationState { state }

    /// Hotkey down. Starts the capture pipeline. Re-entrant calls while
    /// already in `.recording` or `.processing` are no-ops.
    public func handleKeyDown() async {
        guard case .idle = state else {
            Self.log.debug("keyDown ignored — state is \(String(describing: self.state), privacy: .public)")
            return
        }
        do {
            try await capture.start()
            state = .recording
            await hud?.update(state: .recording)
        } catch {
            state = .error("Failed to start: \(error)")
            await hud?.update(state: .error("\(error)"))
            // Fall back to idle after a short window so the user can retry.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            state = .idle
            await hud?.update(state: .idle)
        }
    }

    /// Hotkey up. Stops the mic, trims silence, transcribes, injects.
    /// No-op if we're not currently recording.
    public func handleKeyUp() async {
        guard case .recording = state else { return }

        state = .processing
        await hud?.update(state: .processing)

        let result = await capture.stop()
        let trimmed = vad.trim(result.samples)
        guard !trimmed.isEmpty else {
            // Either the user released without speaking or VAD trimmed
            // everything as silence. Quietly back to idle.
            state = .idle
            await hud?.update(state: .idle)
            return
        }

        let text: String
        do {
            text = try await transcriber.transcribe(
                samples: trimmed,
                initialPrompt: initialPromptProvider()
            )
        } catch {
            state = .error("Transcription failed: \(error)")
            await hud?.update(state: .error("Transcription failed"))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            state = .idle
            await hud?.update(state: .idle)
            return
        }

        guard !text.isEmpty else {
            state = .idle
            await hud?.update(state: .idle)
            return
        }

        // Try primary (AX) → fallback (clipboard) on miss/throw.
        do {
            let inserted = try await primaryInjector.insert(text)
            if !inserted {
                _ = try await fallbackInjector.insert(text)
            }
        } catch {
            // Primary threw — try the fallback unconditionally.
            _ = try? await fallbackInjector.insert(text)
        }

        state = .idle
        await hud?.update(state: .idle)
    }

    private static let log = Logger(subsystem: "dev.murmur", category: "coordinator")
}
