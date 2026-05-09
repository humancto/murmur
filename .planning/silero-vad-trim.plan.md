# Plan — `silero-vad-trim`

**Roadmap item:** `- [ ] silero-vad-trim` (item 4, milestone v0.1).

**Goal:** Remove leading and trailing silence from a captured `[Float]` so Whisper doesn't hallucinate transcripts on dead air ("Thanks for watching!", "Subscribe to my channel"). This is the architecture-plan §2.2 hallucination-prevention move.

## Deviation from ROADMAP name

The roadmap item is named `silero-vad-trim`. **The v0.1 implementation is an in-house energy-based VAD, not Silero.** Reasoning:

- The actual goal is "trim leading/trailing silence." That's what stops Whisper hallucinations. Silero is a _means_, not the _end_.
- Silero needs a CoreML model file (~1.5 MB, but distribution surface), a CoreML wrapper, and inference plumbing — meaningful complexity for v0.1.
- Energy-thresholded VAD over 30 ms windows is ~50 lines of pure Swift, fully testable with the existing `ToneGenerator`, and _good enough_ for the leading/trailing trim use case in clean dictation conditions (close-mic, indoor, single speaker).
- Silero earns its keep when you need _intra-speech_ segmentation (where short pauses between words must be classified) or noisy environments. Neither is the v0.1 use case.

**Silero stays on the roadmap as a v0.5 upgrade** if accent eval shows energy-VAD failing on quiet speakers or noisy environments. The API shape (`VAD.trim([Float]) -> [Float]`) is identical, so swapping implementations is a one-file change.

If apple-expert pushes back and says Silero is the right call now, I'll reverse course. But the bar for adding a CoreML model dependency at v0.1 should be high.

## What ships

```
Sources/MurmurCore/
├── MurmurInfo.swift            (unchanged)
├── ModelCache.swift            (unchanged)
├── Resampler.swift             (unchanged)
├── AudioCapture.swift          (unchanged)
└── VAD.swift                   (new — pure Swift, energy-based, deterministic)

Tests/MurmurCoreTests/
├── (existing tests)
└── VADTests.swift              (new — 7 swift-testing tests)
```

## VAD design

```swift
private import Foundation

/// Removes leading and trailing silence from a captured audio buffer.
///
/// v0.1 implementation: window-RMS energy threshold. Suitable for the
/// leading/trailing trim use case in clean dictation. A Silero-CoreML
/// upgrade is tracked for v0.5 if accent evals show this failing on
/// quiet speakers or noisy environments.
public struct VAD: Sendable {

    public struct Config: Sendable {
        /// Sample rate of the input. Must match what Resampler.whisperTarget produces.
        public var sampleRate: Double
        /// Window duration in ms. 30 ms is the standard VAD frame size.
        public var windowDurationMs: Double
        /// Threshold in dBFS. Above = speech, below = silence. `-40` is conservative
        /// for close-mic dictation; tune downward if quiet speakers get clipped.
        public var energyThresholdDBFS: Float
        /// Pre-roll preserved before the first speech window so we don't clip word starts.
        public var leadingPadMs: Double
        /// Post-roll preserved after the last speech window so we don't clip word ends.
        public var trailingPadMs: Double
        /// Minimum total speech duration. Captures shorter than this return `[]`
        /// (almost certainly accidental hotkey bumps).
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

    /// Trim leading and trailing silence. **Does not trim intra-speech silence**
    /// — gaps between words inside the speech region are preserved.
    ///
    /// Returns `[]` if no speech is detected, or if total detected speech is
    /// shorter than `config.minSpeechMs`.
    public func trim(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let windowSize = max(1, Int(config.windowDurationMs * config.sampleRate / 1000))
        guard samples.count >= windowSize else { return [] }

        let thresholdLinear = pow(10, config.energyThresholdDBFS / 20)
        let thresholdSq = Double(thresholdLinear * thresholdLinear)

        // Walk windows, mark speech windows by RMS-squared > thresholdSq.
        // (Squaring saves a sqrt per window without changing the comparison.)
        var firstSpeech: Int? = nil
        var lastSpeech: Int? = nil

        var windowStart = 0
        while windowStart + windowSize <= samples.count {
            var sumSq: Double = 0
            for i in windowStart..<(windowStart + windowSize) {
                let s = Double(samples[i])
                sumSq += s * s
            }
            let meanSq = sumSq / Double(windowSize)
            if meanSq > thresholdSq {
                if firstSpeech == nil { firstSpeech = windowStart }
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
```

### Design choices, defended

- **Window-RMS energy threshold.** Industry-standard cheap VAD baseline. Good for leading/trailing trim under close-mic conditions.
- **Squared comparison without sqrt.** Saves one sqrt per window; numerically identical for the comparison.
- **`Sendable` struct.** Crosses actor boundaries from `AudioCapture` to whichever consumer trims (likely the upcoming end-to-end wiring item).
- **`-40 dBFS` default.** Conservative for typical close-mic dictation. Won't clip ordinary speech; will catch HVAC noise as silence.
- **`minSpeechMs = 100` default.** Filters accidental hotkey bumps where the user doesn't actually speak.
- **No intra-speech trimming.** Cutting gaps between words breaks Whisper's prosodic context and risks merging unrelated phrases. We trim only the silent prefix and suffix.
- **Pure value type, no state, no I/O.** Fully unit-testable without the audio engine or any system surface.
- **`private import Foundation`** — Foundation types (`pow`, `Array`, etc.) used internally; not exposed in the public API. No `public import` needed (lesson from PR #2).

## Tests (mandatory)

`VADTests.swift`, swift-testing, 7 tests. All use `ToneGenerator` — no fixture files, no mic.

1. **`empty input returns empty`** — `vad.trim([])` → `[]`.
2. **`pure silence returns empty`** — 1 s of zero-amplitude samples → `[]`.
3. **`pure tone returns most of the input within tolerance`** — 1 s of 1 kHz tone at amplitude 0.5 → output length ≈ 1 s + leading+trailing pad clamps. Asserts: output is non-empty, output length is within ±1 window of input length (because edge windows still classify as speech, padding is bounded by buffer ends).
4. **`silence-then-tone-then-silence returns ~tone portion plus pads`** — 0.5 s silence + 0.5 s tone + 0.5 s silence (1.5 s total at 16 kHz = 24,000 samples). Output length should be ≈ 0.5 s + leading + trailing pads = ≈ 0.8 s. Tolerance ±1 window.
5. **`tone-then-silence-then-tone preserves intra-speech gap`** — 0.3 s tone + 0.4 s silence + 0.3 s tone. Output length should be ≈ 1.0 s + pads (no intra-speech trimming).
6. **`speech below minSpeechMs returns empty`** — 50 ms tone (< default 100 ms `minSpeechMs`) → `[]`.
7. **`config knobs change behavior`** — same input, two configs differing only in `energyThresholdDBFS`; the looser threshold trims more aggressively (catches lower-amplitude regions).

## Acceptance criteria

- [ ] `Sources/MurmurCore/VAD.swift` exists with the API above
- [ ] `Tests/MurmurCoreTests/VADTests.swift` exists with 7 tests
- [ ] `swift build` clean, no warnings
- [ ] `swift test` exits 0 with **24** tests passing (17 prior + 7 new)
- [ ] No new dependencies on `Package.swift`
- [ ] Branch: `feat/silero-vad-trim` (keeping ROADMAP item slug for traceability even though impl differs)
- [ ] Single squash-merged PR
- [ ] PR body explicitly calls out the Silero → energy-based deviation so reviewers see it

## Risks

- **Energy threshold fails in noisy environments.** Documented limitation. Silero v0.5 upgrade is the mitigation.
- **Quiet speakers get clipped.** `-40 dBFS` is the threshold; tunable via `Config.energyThresholdDBFS`. If accent eval shows this failing for the author's voice, lower to `-45` and re-run.
- **Whisper still hallucinates on noise that _isn't_ silence.** This VAD only trims silence — it doesn't fix the "background hum interpreted as speech" failure mode. That needs Silero or a noise gate.
- **Window-size aliasing.** With 30 ms windows at 16 kHz = 480 samples, very short utterances (< window) return `[]`. Already handled by `samples.count >= windowSize` guard at the top.
- **Off-by-one on `lastSpeech`.** I set `lastSpeech = windowStart + windowSize` (the _end_ of the last speech window, exclusive). `samples[lo..<hi]` is half-open. Correct, but it's the kind of thing apple-expert should sanity-check.

## Apple-expert revisions applied

Verdict was **APPROVE** on the deviation (energy-based VAD is the right v0.1 call) and the algorithm. Two small must-fixes:

1. **Verify `pow` import path** — under `InternalImportsByDefault` and `private import Foundation`, the `pow(10, dBFS/20)` call must resolve cleanly. If `pow` resolves via `Darwin` instead of `Foundation` on this toolchain, switch to `private import Darwin` to keep the dependency truthful. Will verify during build; either choice is internal-only, no API impact.
2. **Add a 7th test** for the "exactly one speech window detected" edge case — input contains a single 30 ms speech window (total speech duration < `minSpeechMs` 100 ms) → returns `[]`. Confirms the off-by-one on `lastSpeech = windowStart + windowSize` produces the right `speechDurationMs` math.

Plus useful guidance:

- **`-40 dBFS`** reasonable for close-mic. Likely clips whispered speech and quiet voices — flag in accent eval; if seen, drop to `-45` default and add a `Sensitivity` enum in v1.1. Never ship a raw dB slider to users.
- **`100/200 ms` lead/trail asymmetry is right** — trailing fricatives (`/s/`, `/f/`) and unvoiced stops decay slowly; they matter more than onsets for Whisper's tokenization.
- **No intra-speech trimming is correct** — Whisper is trained on continuous speech with natural pauses; mid-utterance gap removal corrupts prosody and is a known cause of word-merging hallucinations.
- **`throws` is over-engineering** — keep `[]` return.
- **`VAD` swap-in-place naming is right** — contract is the API; implementation is private. If/when Silero lands, expose a `VAD.Engine` enum or protocol.
- Doc-comment the `windowSize == 0` impossibility (the `max(1, ...)` already prevents it; comment why).

## Open questions for apple-expert (resolved in review)

1. **Silero vs energy-based for v0.1.** Defended above. Push back if you disagree.
2. **Threshold default `-40 dBFS`.** Reasonable for close-mic dictation? Too aggressive? Too loose?
3. **Pad defaults `100 / 200 ms`.** Catches word starts/ends without bringing back too much silence?
4. **`minSpeechMs = 100 ms` minimum.** Right floor for "user actually spoke" vs accidental bump?
5. **Should `trim()` be `throws`?** Currently returns `[]` for "no speech detected." A typed error (e.g., `.noSpeechDetected`) would let the caller distinguish "user spoke nothing" from "user spoke and we trimmed it down to nothing." Worth it?
6. **VAD config exposed via the architecture plan's user-vocabulary editor pattern**, or is energy threshold an internal-only knob? My instinct is internal-only for v1.0; users get a "sensitivity" slider in v1.1 if accent eval requires it.
7. **Whisper is fed silence-trimmed audio. Does that hurt the "context window" of large-v3-turbo?** Whisper expects 30 s chunks (it pads internally). If we trim a 10 s utterance to 4 s, Whisper still pads to 30 s. So we lose nothing on context — and we gain back the time Whisper would otherwise spend hallucinating on the trimmed silence. Confirm or correct.
8. **Naming.** `VAD` is generic; should this be `EnergyVAD` (with a future `SileroVAD` alongside) or just `VAD` with the impl swap-in-place? I lean swap-in-place — the API is the contract, the impl is private.
