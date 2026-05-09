@preconcurrency public import WhisperKit
public import Foundation
private import os

/// Production transcriber wrapping WhisperKit. Lazily loads the model
/// on first transcription so app startup isn't blocked.
///
/// Default model: `openai_whisper-small.en` per apple-expert review —
/// `base.en` is too rough on accented English (the project's whole
/// pitch). `small.en` is ~480 MB, the smallest model defensible for
/// accent quality. `large-v3-turbo` is the v0.5 upgrade once first-run
/// download UI lands.
public actor WhisperKitTranscriber: Transcribing {

    public let modelName: String
    public let modelFolder: URL?

    private var pipe: WhisperKit?
    private var loadTask: Task<Void, any Error>?

    public init(
        modelName: String = "openai_whisper-small.en",
        modelFolder: URL? = ModelCache.production.baseDirectory
    ) {
        self.modelName = modelName
        self.modelFolder = modelFolder
    }

    /// Pre-warm the model. Safe to call multiple times — second call is
    /// a no-op while the first is still loading. Returns `Void` because
    /// `WhisperKit` isn't `Sendable`; the loaded instance lives on the
    /// actor as `pipe` and is consumed only inside `transcribe`.
    public func warmUp() async throws {
        if pipe != nil { return }
        if let existing = loadTask {
            try await existing.value
            return
        }
        let modelName = self.modelName
        let modelFolderPath = self.modelFolder?.path
        let task = Task { [weak self] in
            let loaded = try await WhisperKit(
                model: modelName,
                modelFolder: modelFolderPath
            )
            await self?.assignPipe(loaded)
        }
        loadTask = task
        // Clear the load task on both success AND failure. Earlier code
        // only nilled on throw; on success the completed Task lingered
        // as actor state forever, pinning memory. apple-expert flagged
        // this as a future-blocker for v0.5.1 idle-unload work.
        defer { self.loadTask = nil }
        try await task.value
    }

    private func assignPipe(_ pipe: WhisperKit) {
        self.pipe = pipe
    }

    public func transcribe(samples: [Float], initialPrompt: String?) async throws -> String {
        guard !samples.isEmpty else { return "" }
        try await warmUp()
        guard let pipe else { return "" }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            temperatureFallbackCount: 0,
            sampleLength: 224,
            usePrefillPrompt: true,
            withoutTimestamps: true
        )

        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        // WhisperKit returns an array of TranscriptionResult fragments;
        // join them and strip leading/trailing whitespace.
        let joined = results.map { $0.text }.joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private static let log = Logger(subsystem: "dev.murmur", category: "transcriber")
}
