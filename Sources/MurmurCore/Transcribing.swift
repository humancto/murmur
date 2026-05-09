public import Foundation

/// Transcription contract. Production implementation wraps WhisperKit;
/// tests substitute a stub. Pluggable so DictationCoordinator can be
/// fully unit-tested without spinning up CoreML.
public protocol Transcribing: Sendable {
    /// Transcribe 16 kHz mono float32 PCM samples to text. Throws on
    /// inference failure. Returns the empty string if the audio
    /// transcribed to nothing (empty input, all-silence-after-VAD,
    /// model decoded to no text).
    func transcribe(samples: [Float], initialPrompt: String?) async throws -> String
}
