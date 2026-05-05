@preconcurrency public import AVFoundation
private import Foundation
private import os

/// Single-threaded-by-construction wrapper around `AVAudioConverter`
/// for shipping into the tap closure. The converter is touched on the
/// audio thread between `installTap` and `removeTap`, then on the
/// actor thread for the flush. The two regions are temporally
/// disjoint, but the compiler can't prove it.
private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    init(_ converter: AVAudioConverter) { self.converter = converter }
}

public enum AudioCaptureError: Error, Sendable {
    case microphonePermissionDenied
    case unsupportedConversion(inputFormat: AVAudioFormat)
    case engineStartFailed(underlying: any Error)
}

/// Captures microphone audio and resamples it to Whisper's required
/// 16 kHz mono float32 format. Hold-to-talk lifecycle: `start()` opens
/// the mic and begins accumulating samples; `stop()` returns the
/// captured samples plus a `didCap` flag indicating whether the
/// `maxCaptureDuration` truncation hit.
public actor AudioCapture {

    /// Per architecture plan §9.13 — single-utterance hard cap.
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
        // Explicit permission request — don't rely on the engine's opaque
        // platform-version-dependent error on denial.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioCaptureError.microphonePermissionDenied }

        guard engine == nil else { return }
        buffer.withLock { $0 = State() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: Resampler.whisperTarget) else {
            throw AudioCaptureError.unsupportedConversion(inputFormat: inputFormat)
        }
        let box = ConverterBox(converter)

        let bufferLock = self.buffer
        let maxSamples = Int(Self.maxCaptureDuration * Resampler.whisperTarget.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) {
            [box, bufferLock, maxSamples] pcm, _ in
            // Don't crash the audio thread on resample failure — drop the chunk.
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
    public func stop() -> (samples: [Float], didCap: Bool) {
        guard let engine, let box = converterBox else { return ([], false) }

        // Stop engine first → no new tap callbacks. Then remove the tap.
        // After this point the audio thread is no longer touching
        // `box.converter`, so the actor can use it for the flush.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.converterBox = nil

        let dummy = AVAudioPCMBuffer(pcmFormat: box.converter.inputFormat, frameCapacity: 1)
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

    // TODO (post-v0.1): observe `AVAudioEngineConfigurationChange` to
    // handle mic device disconnection mid-capture (Bluetooth headset
    // unplug, mic switch, etc). Tracked as a follow-up.
}
