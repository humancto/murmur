private import Foundation

/// Removes leading and trailing silence from a captured audio buffer.
///
/// v0.1 implementation: window-RMS energy threshold. Suitable for the
/// leading/trailing trim use case in clean dictation. A Silero-CoreML
/// upgrade is tracked for v0.5 if accent evals show this failing on
/// quiet speakers or noisy environments.
///
/// Does **not** trim intra-speech silence — gaps between words inside
/// the speech region are preserved. Cutting them would corrupt Whisper's
/// prosodic context and is a known cause of word-merging hallucinations.
public struct VAD: Sendable {

    public struct Config: Sendable {

        /// Sample rate of the input. Must match what `Resampler.whisperTarget`
        /// produces (16 kHz) when chained with `AudioCapture`.
        public var sampleRate: Double

        /// Window duration in milliseconds. 30 ms is the standard VAD frame
        /// size; non-overlapping windows are sufficient for trim.
        public var windowDurationMs: Double

        /// Threshold in dBFS. Above = speech, below = silence. `-40` is
        /// conservative for close-mic dictation. Internal-only knob — don't
        /// expose to users; tune via `Sensitivity` in v1.1.
        public var energyThresholdDBFS: Float

        /// Pre-roll preserved before the first speech window so we don't
        /// clip word starts.
        public var leadingPadMs: Double

        /// Post-roll preserved after the last speech window so we don't
        /// clip trailing fricatives, which decay slowly and matter more
        /// than onsets for Whisper's tokenization. Asymmetry is intentional.
        public var trailingPadMs: Double

        /// Minimum total detected speech duration. Captures shorter than
        /// this return `[]` (almost certainly accidental hotkey bumps).
        public var minSpeechMs: Double

        public init(
            sampleRate: Double = 16_000,
            windowDurationMs: Double = 30,
            energyThresholdDBFS: Float = -40,
            leadingPadMs: Double = 100,
            trailingPadMs: Double = 200,
            minSpeechMs: Double = 100
        ) {
            self.sampleRate = sampleRate
            self.windowDurationMs = windowDurationMs
            self.energyThresholdDBFS = energyThresholdDBFS
            self.leadingPadMs = leadingPadMs
            self.trailingPadMs = trailingPadMs
            self.minSpeechMs = minSpeechMs
        }
    }

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Trim leading and trailing silence. Returns `[]` if no speech is
    /// detected, or if total detected speech is shorter than
    /// `config.minSpeechMs`.
    public func trim(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        // `max(1, ...)` defends against pathological configs (zero or
        // negative window/sample-rate). Real configs land at 480 here.
        let windowSize = max(1, Int(config.windowDurationMs * config.sampleRate / 1000))
        guard samples.count >= windowSize else { return [] }

        // Squared comparison saves a sqrt per window without changing the
        // ordering. Threshold in dBFS → linear amplitude → squared.
        let thresholdLinear = pow(10, config.energyThresholdDBFS / 20)
        let thresholdSq = Double(thresholdLinear * thresholdLinear)

        var firstSpeech: Int? = nil
        var lastSpeech: Int? = nil

        var windowStart = 0
        while windowStart + windowSize <= samples.count {
            // Double accumulator for numerical stability across multi-second
            // buffers. Per-window cost is negligible.
            var sumSq: Double = 0
            for i in windowStart..<(windowStart + windowSize) {
                let s = Double(samples[i])
                sumSq += s * s
            }
            let meanSq = sumSq / Double(windowSize)
            if meanSq > thresholdSq {
                if firstSpeech == nil { firstSpeech = windowStart }
                // Exclusive upper bound — paired with the half-open slice below.
                lastSpeech = windowStart + windowSize
            }
            windowStart += windowSize
        }

        guard let start = firstSpeech, let end = lastSpeech else { return [] }

        let speechDurationMs = Double(end - start) / config.sampleRate * 1000
        guard speechDurationMs >= config.minSpeechMs else { return [] }

        let leadingPad = Int(config.leadingPadMs * config.sampleRate / 1000)
        let trailingPad = Int(config.trailingPadMs * config.sampleRate / 1000)
        let lo = max(0, start - leadingPad)
        let hi = min(samples.count, end + trailingPad)
        return Array(samples[lo..<hi])
    }
}
