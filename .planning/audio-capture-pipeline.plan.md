# Plan — `audio-capture-pipeline`

**Roadmap item:** `- [ ] audio-capture-pipeline` (item 3, milestone v0.1).

**Goal:** Capture microphone audio at 16 kHz mono float32 — the format Whisper expects. Two pieces:

1. **`Resampler`** — pure function over `AVAudioPCMBuffer`. Wraps `AVAudioConverter` to convert _any_ input format (typically 44.1 / 48 kHz interleaved stereo from the default mic) into `[Float]` at 16 kHz mono. No mic, no engine, no actor — testable directly.
2. **`AudioCapture` actor** — wraps `AVAudioEngine`, installs an input tap, runs each tap-buffer through the `Resampler`, accumulates samples in a thread-safe buffer. `start()` / `stop() -> [Float]` API. The mic-touching surface.

Splitting them is the move that makes this PR-sized: `Resampler` is fully testable without TCC mic prompts; `AudioCapture` gets a thin smoke test and a manual-only sanity check.

## What ships

```
Sources/MurmurCore/
├── MurmurInfo.swift            (unchanged)
├── ModelCache.swift            (unchanged)
├── Resampler.swift             (new — pure function, fully tested)
└── AudioCapture.swift          (new — actor wrapping AVAudioEngine + Resampler)

Tests/MurmurCoreTests/
├── MurmurInfoTests.swift       (unchanged)
├── ModelCacheTests.swift       (unchanged)
├── ResamplerTests.swift        (new — programmatic tone fixtures, 5+ tests)
├── AudioCaptureTests.swift     (new — non-mic smoke tests + lifecycle)
└── TestSupport/
    └── ToneGenerator.swift     (new — programmatic AVAudioPCMBuffer tone fixtures)
```

No fixture WAV files committed — programmatic tone synthesis keeps the repo lean and the tests self-contained.

## Resampler design (revised — apple-expert review)

Stateless namespace with one streaming function. **The converter is owned by `AudioCapture`, not `Resampler`** — apple-expert flagged that allocating a fresh `AVAudioConverter` per tap buffer drops samples (filter-state discontinuities at every ~85 ms boundary; the converter's flushed tail is also lost). Converter is cached at `start()` and held across all buffers; `stop()` drives the final flush.

```swift
public import AVFoundation

public enum Resampler {

    /// Whisper's required input format: 16 kHz mono PCM float32, non-interleaved.
    /// Force-unwrap is justified — this exact combination is valid on every
    /// Apple platform Murmur targets.
    public static let whisperTarget = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Run one chunk through a caller-provided converter. The converter
    /// holds the streaming filter state; pass the same instance across
    /// all chunks of a capture, then call once more with `flush: true` to
    /// drain the converter's internal tail.
    ///
    /// - Parameters:
    ///   - input: A non-empty PCM buffer from the audio engine tap (or a
    ///     dummy zero-frame buffer when only flushing).
    ///   - converter: Long-lived converter built once at capture start.
    ///   - flush: If true, signals end-of-stream to the converter so it
    ///     emits its remaining filter tail. Allocates extra output headroom
    ///     to capture the flushed frames.
    public static func resample(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        flush: Bool = false
    ) throws -> [Float] {
        if input.frameLength == 0 && !flush { return [] }

        // Output capacity. On flush we need extra headroom for the
        // converter's filter tail (group delay can be tens of frames at
        // high quality). One second of slack at the target rate is cheap
        // and bullet-proof.
        let target = converter.outputFormat
        let ratio = target.sampleRate / input.format.sampleRate
        let baseCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        let outCapacity = flush
            ? baseCapacity + AVAudioFrameCount(target.sampleRate)
            : baseCapacity

        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(outCapacity, 1)) else {
            throw ResamplerError.outputBufferAllocationFailed
        }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if flush && (input.frameLength == 0 || fed) {
                statusPtr.pointee = .endOfStream
                return nil
            }
            if !fed {
                fed = true
                statusPtr.pointee = .haveData
                return input
            }
            // Streaming (non-flush) call: tell the converter we have nothing
            // more *for this chunk*; do not signal endOfStream.
            statusPtr.pointee = .noDataNow
            return nil
        }

        if let error { throw ResamplerError.conversionFailed(underlying: error) }
        if status == .error { throw ResamplerError.conversionFailed(underlying: nil) }

        guard let channelData = output.floatChannelData else {
            throw ResamplerError.outputHadNoFloatChannelData
        }
        let count = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}

public enum ResamplerError: Error, Sendable {
    case outputBufferAllocationFailed
    case conversionFailed(underlying: NSError?)
    case outputHadNoFloatChannelData
}
```

Notes:

- **No more `ResamplerError.unsupportedConversion`** — that error path moved to `AudioCapture.start()` where we attempt to construct the converter and throw a typed `AudioCaptureError.unsupportedConversion(inputFormat)`.
- **Streaming uses `.noDataNow`** for non-flush calls. Critical — `.endOfStream` per buffer would lose the tail we want to keep.
- **`public import AVFoundation`** still required — `AVAudioPCMBuffer` and `AVAudioConverter` are public-API parameters.

## AudioCapture design (revised — apple-expert review)

Actor wrapping the mic. Buffer accumulates resampled `[Float]`. The tap callback is _not_ on the actor (audio threads can't be), so we use `OSAllocatedUnfairLock` for the buffer. The `AVAudioConverter` is owned by the actor and shared into the closure via an `@unchecked Sendable` box (single-threaded use is enforced by the audio engine's serial callback contract).

```swift
public import AVFoundation
private import Foundation
private import os

/// Pinned discipline: the `AVAudioConverter` is touched on the audio
/// thread only while the tap is installed; on `stop()` after `removeTap`,
/// the actor flushes it. The two regions are temporally disjoint, but
/// the compiler can't prove it. The unchecked-Sendable wrapper encodes
/// this single-threaded-by-construction invariant.
private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    init(_ c: AVAudioConverter) { self.converter = c }
}

public enum AudioCaptureError: Error, Sendable {
    case microphonePermissionDenied
    case unsupportedConversion(inputFormat: AVAudioFormat)
    case engineStartFailed(underlying: any Error)
}

public actor AudioCapture {

    /// Per architecture plan §9.13 — single capture cap.
    public static let maxCaptureDuration: TimeInterval = 60

    private struct State {
        var samples: [Float] = []
        var didCap: Bool = false
    }

    private let buffer = OSAllocatedUnfairLock<State>(initialState: State())
    private var engine: AVAudioEngine?
    private var converterBox: ConverterBox?

    public init() {}

    public var isCapturing: Bool { engine != nil }

    public func start() async throws {
        // 1. Explicit mic permission. Don't rely on AVAudioEngine's opaque
        //    error — it's platform-version-dependent. async/await gives us
        //    a clean denial code path the UI layer can render.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioCaptureError.microphonePermissionDenied }

        guard engine == nil else { return }
        buffer.withLock { $0 = State() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Build the converter once; it carries streaming filter state
        // across every tap buffer.
        guard let converter = AVAudioConverter(from: inputFormat, to: Resampler.whisperTarget) else {
            throw AudioCaptureError.unsupportedConversion(inputFormat: inputFormat)
        }
        let box = ConverterBox(converter)

        let bufferLock = self.buffer
        let maxSamples = Int(Self.maxCaptureDuration * Resampler.whisperTarget.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) {
            [box, bufferLock, maxSamples] pcm, _ in
            // Don't crash the audio thread on resample failure — drop the chunk silently.
            let chunk = (try? Resampler.resample(pcm, using: box.converter, flush: false)) ?? []
            guard !chunk.isEmpty else { return }
            bufferLock.withLock { state in
                guard !state.didCap else { return }
                state.samples.append(contentsOf: chunk)
                if state.samples.count >= maxSamples {
                    state.samples = Array(state.samples.prefix(maxSamples))
                    state.didCap = true
                }
            }
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(underlying: error)
        }
        self.engine = engine
        self.converterBox = box
    }

    /// Stop capture, flush the converter's filter tail, drain the buffer.
    /// Returns the captured samples and `didCap` for the UI layer.
    public func stop() -> (samples: [Float], didCap: Bool) {
        guard let engine, let box = converterBox else { return ([], false) }

        // Stop engine first — prevents new tap callbacks. Then remove the
        // tap. After this point the audio thread is no longer touching
        // `box.converter`, so the actor can use it for the flush.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.converterBox = nil

        // Flush. Feed a zero-frame buffer in the input format and let
        // the converter emit its remaining internal samples.
        let dummy = AVAudioPCMBuffer(
            pcmFormat: box.converter.inputFormat,
            frameCapacity: 1
        )
        dummy?.frameLength = 0
        let tail: [Float]
        if let dummy {
            tail = (try? Resampler.resample(dummy, using: box.converter, flush: true)) ?? []
        } else {
            tail = []
        }

        return buffer.withLock { state in
            if !tail.isEmpty && !state.didCap {
                let space = Int(Self.maxCaptureDuration * Resampler.whisperTarget.sampleRate) - state.samples.count
                state.samples.append(contentsOf: tail.prefix(max(space, 0)))
            }
            let drained = state
            state = State()
            return (drained.samples, drained.didCap)
        }
    }
}
```

Notes:

- **Actor + `OSAllocatedUnfairLock`** — tap callback runs on a real-time audio thread that can't await actor isolation; the lock bridges the two domains.
- **`@unchecked Sendable` `ConverterBox`** — encodes the single-threaded-by-construction discipline. Converter is touched on the audio thread between `installTap` and `removeTap`, then on the actor for the flush. Never overlapping. This is the documented Swift-6 escape hatch for non-`Sendable` framework types.
- **Explicit `AVCaptureDevice.requestAccess(for: .audio)`** in `start()` (apple-expert must-fix #3) — clean async denial path; UI item handles onboarding.
- **`stop()` returns `(samples, didCap)`** (must-fix #4) — UI item reads `didCap` to render "you hit the cap" feedback.
- **Engine-start failure cleanup** — if `engine.start()` throws, we remove the tap before re-throwing so a retry isn't poisoned.
- **TODO (post-v0.1):** observe `AVAudioEngineConfigurationChange` notification to handle mic device disconnection mid-capture. Tracked as a follow-up; not v0.1 blocker.

## Tests

### `ResamplerTests.swift` (5 tests, no mic — converter constructed in each test)

Each test constructs an `AVAudioConverter(from: <input format>, to: Resampler.whisperTarget)` and feeds chunks through it, ending with a `flush: true` call to drain the tail. This mirrors what `AudioCapture` does in production.

- **`resamples 44_100 mono → 16_000 mono with expected sample count`** — generate 1 s of 1 kHz tone at 44.1 kHz mono, resample (one streaming call + one flush), assert sample count ≈ 16_000 within tolerance.
- **`resamples 48_000 stereo → 16_000 mono`** — generate 0.5 s of stereo, resample with flush, assert mono output length and no NaN/inf.
- **`empty input + no flush returns empty`** — `frameLength == 0`, `flush: false` → `[]`.
- **`preserves a sinusoid's RMS within tolerance`** — known-amplitude tone, resample with flush, assert output RMS ≈ input RMS within 5%. Catches "converter silently outputs zeros" regressions, which is the failure mode apple-expert flagged that drove this whole rework.
- **`flush after multiple chunks recovers expected total length`** — feed 4 × 0.25 s tone chunks streaming, then flush, assert total length ≈ 16_000. Direct regression test for the per-buffer-allocation bug we just fixed.

### `AudioCaptureTests.swift` (3 tests)

The audio engine touches the system mic. We can't reliably unit-test that on every machine. Instead:

- **`stop without start returns empty samples and didCap=false`** — actor lifecycle.
- **`isCapturing is false initially`** — actor state default.
- **`start then stop returns a result tuple` (gated by `@Test(.disabled(if:))`)** — best-effort smoke test that the engine boots, the tap installs, and `stop()` returns the tuple. Disabled when `MURMUR_SKIP_AUDIO_HARDWARE` env var is present (apple-expert must-fix #5 — idiomatic swift-testing trait, not a manual `if` inside the body).

`MURMUR_SKIP_AUDIO_HARDWARE=1` is the contributor-facing escape hatch. Documented in `CONTRIBUTING.md`.

### `TestSupport/ToneGenerator.swift`

```swift
import AVFoundation

enum ToneGenerator {
    static func sine(
        frequency: Double,
        durationSec: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount = 1
    ) -> AVAudioPCMBuffer { /* ... */ }
}
```

Programmatic, deterministic, no fixture files in the repo.

## Acceptance criteria

- [ ] `Sources/MurmurCore/Resampler.swift` exists with the API above
- [ ] `Sources/MurmurCore/AudioCapture.swift` exists, `actor` shape, `Sendable`
- [ ] `Tests/MurmurCoreTests/ResamplerTests.swift` — 5 tests, all passing without mic access
- [ ] `Tests/MurmurCoreTests/AudioCaptureTests.swift` — 3 tests, the engine smoke test gated by `MURMUR_SKIP_AUDIO_HARDWARE`
- [ ] `Tests/MurmurCoreTests/TestSupport/ToneGenerator.swift` — programmatic sine generator
- [ ] `swift build` clean, no warnings
- [ ] `swift test` exits 0 with all tests passing locally (mic prompt may appear once on first run)
- [ ] `CONTRIBUTING.md` documents the `MURMUR_SKIP_AUDIO_HARDWARE` env var
- [ ] Branch: `feat/audio-capture-pipeline`
- [ ] Single squash-merged PR

## Risks

- **TCC microphone prompt during `swift test`.** First-time contributors will see a system dialog when the AudioCapture smoke test runs. The env-var skip lets them bypass cleanly. Doc it loudly.
- **`AVAudioEngine` Swift-6 sendability.** It's not `Sendable`. We never let it cross actor boundaries — it's stored as an `var engine: AVAudioEngine?` _on_ the actor and only touched from inside. The closure captures `[resampler, bufferLock, maxSamples]` — none of which include the engine. Should be sound; apple-expert please verify.
- **`AVAudioConverter` per-call allocation cost.** Negligible compared to a tap buffer's RMS calculation; profile if it ever shows up. For now, simpler is correct.
- **`OSAllocatedUnfairLock` blocking the audio thread.** Real-time audio threads should not block. `os_unfair_lock` is non-blocking when uncontended (the common case — only `start()` and `stop()` contend), and `OSAllocatedUnfairLock` wraps it. Acceptable.
- **Format change mid-capture** (mic disconnect / device switch). Tap callback would receive a buffer in a new format; `Resampler` re-allocates the converter and continues. No state lost on the actor side. Untested; flagged as a risk, not a v0.1 blocker.

## Apple-expert revisions applied

1. **Converter cached on `AudioCapture`**, not allocated per buffer. `Resampler` becomes a stateless namespace that takes the converter as a parameter. Drives streaming with `.noDataNow` per chunk and `.endOfStream` only on the final flush. Fixes the silent-sample-loss correctness bug.
2. **Flush headroom** — `outCapacity` includes `+ AVAudioFrameCount(target.sampleRate)` (1 s of slack) on the flushing call to capture the converter's filter tail. Cheap memory; correctness wins.
3. **Explicit `await AVCaptureDevice.requestAccess(for: .audio)`** in `start()`. Throws typed `AudioCaptureError.microphonePermissionDenied`.
4. **`stop()` returns `(samples, didCap)`** so the UI layer can render the cap-hit state without re-architecting the actor.
5. **swift-testing skip trait**, `@Test(.disabled(if: ...))`, replaces the manual env-var check inside the test body.

Plus structural changes derived from the must-fixes:

- New `AudioCaptureError` enum (`microphonePermissionDenied`, `unsupportedConversion`, `engineStartFailed`).
- `ResamplerError.unsupportedConversion` removed (the error path moved to `AudioCapture.start()`).
- `static let maxCaptureDuration: TimeInterval = 60` on `AudioCapture` instead of an init parameter.
- `@unchecked Sendable ConverterBox` to share the converter into the tap closure with documented single-threaded discipline.
- Engine-start failure path removes the tap before re-throwing.

## Open questions for apple-expert (resolved in review)

1. **Splitting Resampler from AudioCapture is a defensible call** — but does it leak abstraction (now there are two types where one would do)? I think no: the testability win is real, the AudioCapture surface stays thin. Sanity-check.
2. **`OSAllocatedUnfairLock` vs `Mutex` (Synchronization).** Swift 6 introduced `Mutex<T>` in the `Synchronization` module on macOS 15+. Murmur floors at macOS 14, so `OSAllocatedUnfairLock` is the only option — confirm or correct.
3. **`AVAudioConverter` per-call vs cached.** Caching adds a `var converter: AVAudioConverter?` field on `Resampler`, which fights the value-type `Sendable` story. Worth it?
4. **`MURMUR_SKIP_AUDIO_HARDWARE` env var** — is there a more idiomatic Swift-Testing way to skip on hardware-absent runners? `@Test(.disabled(if:))` exists; I could read the env var inside the trait. Recommend?
5. **Sample max: `60s` hard cap**, mirrored from architecture plan §9.13. Drop on overflow? Truncate? Currently truncates and flips a `capping` flag. Architecture plan says "beep, finalize, refuse longer captures" — the beep + UI refusal lives in a later item; here we just truncate silently on the audio side. Right call?
6. **Mic permission flow.** First `start()` triggers the TCC prompt, which can take seconds while the user clicks. Should `start()` `await` the permission resolution explicitly via `AVCaptureDevice.requestAccess(for: .audio)`, or let `engine.start()` throw the implicit denial and surface to the caller? I'm leaning explicit `requestAccess` — gives us a clean async "permission denied" code path.
7. **`installTap` `bufferSize: 4_096` at 48 kHz** ≈ 85 ms of latency before a chunk arrives. Smaller (1024 → ~21 ms) would feel snappier but burns more CPU. The Track 1 live HUD was dropped in §9.3, so latency in the tap doesn't visually matter — but it does matter for the lower bound on `stop() → samples`. Recommend?
8. **Foundation imports under `InternalImportsByDefault`.** `AudioCapture` uses `TimeInterval` (Foundation). `private import Foundation` should hide it from consumers; verify that's the right call vs `public import` (only `AVFoundation` needs to be public since it's the public-API surface). I think `private` is correct here.
