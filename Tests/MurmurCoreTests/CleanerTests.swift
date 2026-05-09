import Foundation
import os
import Testing
import MurmurCore

@Suite("Cleaner")
struct CleanerTests {

    // MARK: - Stub

    /// In-memory `Cleaner` that records every input and lets the test
    /// drive return value, throw, and the skip thresholds explicitly.
    /// Mirrors the contract a real `LlamaCppCleaner` will honor:
    ///   - skip (return verbatim) when whisperLogProb > confidenceSkip
    ///   - skip when text.count < minInputCharsToClean
    ///   - throw on a configured failure
    final class StubCleaner: Cleaner, @unchecked Sendable {

        struct Snapshot: Sendable {
            var calls: Int = 0
            var lastInput: String?
            var lastLogProb: Float?
        }

        let confidenceSkipThreshold: Float
        let minInputCharsToClean: Int
        let throwsOnCall: Bool
        let returnText: String?

        private let state = OSAllocatedUnfairLock<Snapshot>(initialState: .init())

        init(
            confidenceSkipThreshold: Float = -0.3,
            minInputCharsToClean: Int = 25,
            throwsOnCall: Bool = false,
            returnText: String? = nil
        ) {
            self.confidenceSkipThreshold = confidenceSkipThreshold
            self.minInputCharsToClean = minInputCharsToClean
            self.throwsOnCall = throwsOnCall
            self.returnText = returnText
        }

        var snapshot: Snapshot { state.withLock { $0 } }

        func clean(text: String, whisperLogProb: Float?) async throws -> String {
            state.withLock { s in
                s.calls += 1
                s.lastInput = text
                s.lastLogProb = whisperLogProb
            }
            // Honor the contract: confidence + length skips happen
            // before any potential throw. Real implementations should
            // never throw on a skip path.
            if let lp = whisperLogProb, lp > confidenceSkipThreshold {
                return text
            }
            if text.count < minInputCharsToClean {
                return text
            }
            if throwsOnCall {
                throw CleanerError.generationFailed("stub forced throw")
            }
            return returnText ?? text
        }
    }

    // MARK: - Protocol contract

    @Test("high Whisper confidence returns input verbatim")
    func highConfidenceSkipsCleanup() async throws {
        let stub = StubCleaner(returnText: "this should not be returned")
        let result = try await stub.clean(
            text: "this is a long enough sentence to get cleaned in normal flow",
            whisperLogProb: -0.1  // above -0.3 threshold
        )
        #expect(result == "this is a long enough sentence to get cleaned in normal flow")
        #expect(stub.snapshot.lastLogProb == -0.1)
    }

    @Test("low Whisper confidence still cleans")
    func lowConfidenceCleansAsExpected() async throws {
        let stub = StubCleaner(returnText: "Cleaned text.")
        let result = try await stub.clean(
            text: "this is a long enough sentence to get cleaned in normal flow",
            whisperLogProb: -0.5  // below -0.3 threshold
        )
        #expect(result == "Cleaned text.")
    }

    @Test("nil Whisper log-prob disables confidence skip")
    func nilLogProbDisablesSkip() async throws {
        let stub = StubCleaner(returnText: "Cleaned!")
        let result = try await stub.clean(
            text: "this is a long enough sentence to get cleaned in normal flow",
            whisperLogProb: nil
        )
        #expect(result == "Cleaned!")
    }

    @Test("input shorter than minInputCharsToClean returns verbatim")
    func shortInputSkipsCleanup() async throws {
        let stub = StubCleaner(minInputCharsToClean: 25, returnText: "transformed")
        let result = try await stub.clean(text: "short", whisperLogProb: nil)
        #expect(result == "short")
    }

    @Test("CleanerError is Sendable and Equatable-by-construction-shape")
    func cleanerErrorShape() {
        let url = URL(filePath: "/tmp/nope.gguf")
        let errors: [CleanerError] = [
            .modelNotLoaded,
            .generationFailed("oops"),
            .outputCapExceeded,
            .modelFileMissing(url),
        ]
        // We can't `==` Error existentials, but we can confirm the
        // cases compile and surface usefully in `String(describing:)`.
        for e in errors {
            let desc = String(describing: e)
            #expect(!desc.isEmpty)
        }
    }
}
