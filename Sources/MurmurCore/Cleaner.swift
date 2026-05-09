public import Foundation

/// Cleanup pass between transcription and injection. Architecture-plan
/// §2.2: fix punctuation, remove disfluencies, do **not** rephrase.
///
/// The protocol is the seam between `DictationCoordinator` and any
/// concrete cleaner implementation. The production wrap-up around
/// `llama.cpp` + Qwen2.5-3B-Instruct lands in a follow-up PR; this PR
/// ships the seam, the integration into the coordinator, the settings
/// toggle, and stub-driven tests.
public protocol Cleaner: Sendable {
    /// Clean disfluencies and punctuation in `text`.
    ///
    /// Implementations MUST return `text` verbatim (no throw, no
    /// transform) when:
    ///   - `whisperLogProb` is non-nil and above the implementation's
    ///     confidence-skip threshold (architecture-plan §9.8 — high
    ///     Whisper confidence means cleanup is more likely to introduce
    ///     errors than fix them);
    ///   - The input is shorter than the implementation's
    ///     min-input-chars threshold (avoids LLM rewriting trivial
    ///     utterances);
    ///   - The model isn't loaded yet AND lazy load was disabled.
    ///
    /// Throwing is reserved for genuine failures (model load failure,
    /// inference errors, output cap exceeded). The caller
    /// (`DictationCoordinator`) catches all errors and falls through to
    /// raw transcription — cleanup never gates injection.
    ///
    /// Pass `nil` for `whisperLogProb` to disable confidence-based
    /// skip. The plumbing of avg log-prob through `Transcribing` is
    /// tracked as a v0.5.1 follow-up.
    func clean(text: String, whisperLogProb: Float?) async throws -> String
}

public enum CleanerError: Error, Sendable {
    case modelNotLoaded
    case generationFailed(String)
    case outputCapExceeded
    case modelFileMissing(URL)
}
