import AVFoundation
import Testing
import MurmurCore

@Suite("Resampler")
struct ResamplerTests {

    /// Convenience: build a converter from `inputRate / inputChannels` to Whisper's target.
    private func makeConverter(inputRate: Double, inputChannels: AVAudioChannelCount) -> AVAudioConverter {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputRate,
            channels: inputChannels,
            interleaved: false
        )!
        return AVAudioConverter(from: inputFormat, to: Resampler.whisperTarget)!
    }

    @Test("44.1 kHz mono → 16 kHz mono lands within tolerance after streaming + flush")
    func resamples441MonoToWhisperTarget() throws {
        let converter = makeConverter(inputRate: 44_100, inputChannels: 1)
        let tone = ToneGenerator.sine(frequency: 1_000, durationSec: 1.0, sampleRate: 44_100)
        let dummy = ToneGenerator.empty(sampleRate: 44_100)

        let body = try Resampler.resample(tone, using: converter, flush: false)
        let tail = try Resampler.resample(dummy, using: converter, flush: true)
        let total = body + tail

        // 1 s at 16 kHz = 16_000 samples; tolerance for converter group delay rounding
        let drift = abs(total.count - 16_000)
        #expect(drift <= 64, "drift was \(drift), total \(total.count)")
    }

    @Test("48 kHz stereo → 16 kHz mono produces finite samples")
    func resamples48StereoToWhisperTarget() throws {
        let converter = makeConverter(inputRate: 48_000, inputChannels: 2)
        let tone = ToneGenerator.sine(frequency: 440, durationSec: 0.5, sampleRate: 48_000, channels: 2)
        let dummy = ToneGenerator.empty(sampleRate: 48_000, channels: 2)

        let body = try Resampler.resample(tone, using: converter, flush: false)
        let tail = try Resampler.resample(dummy, using: converter, flush: true)
        let total = body + tail

        #expect(!total.isEmpty)
        for s in total { #expect(s.isFinite, "non-finite sample produced") }
        // 0.5 s at 16 kHz ≈ 8_000 samples
        let drift = abs(total.count - 8_000)
        #expect(drift <= 64, "drift was \(drift), total \(total.count)")
    }

    @Test("empty input + no flush returns empty array")
    func emptyInputNoFlushReturnsEmpty() throws {
        let converter = makeConverter(inputRate: 44_100, inputChannels: 1)
        let dummy = ToneGenerator.empty(sampleRate: 44_100)
        let result = try Resampler.resample(dummy, using: converter, flush: false)
        #expect(result.isEmpty)
    }

    @Test("preserves a sinusoid's RMS within 5%")
    func preservesRMS() throws {
        let converter = makeConverter(inputRate: 44_100, inputChannels: 1)
        let tone = ToneGenerator.sine(frequency: 1_000, durationSec: 1.0, sampleRate: 44_100, amplitude: 0.5)
        let dummy = ToneGenerator.empty(sampleRate: 44_100)

        let inputRMS = ToneGenerator.rms(of: tone)
        let body = try Resampler.resample(tone, using: converter, flush: false)
        let tail = try Resampler.resample(dummy, using: converter, flush: true)
        let outputRMS = ToneGenerator.rms(of: body + tail)

        // 5% tolerance — catches "converter silently outputs zeros" regressions.
        let ratio = outputRMS / inputRMS
        #expect(abs(ratio - 1) < 0.05, "rms ratio \(ratio) outside ±5% (in=\(inputRMS), out=\(outputRMS))")
    }

    @Test("streaming multiple chunks then flushing recovers expected total length")
    func streamingChunksAccumulatesCorrectly() throws {
        // Direct regression test for the bug apple-expert flagged: per-chunk
        // converter allocation drops samples at every tap-buffer boundary.
        // Streaming a single converter across N chunks must accumulate to
        // the same total as one big chunk.
        let converter = makeConverter(inputRate: 44_100, inputChannels: 1)
        let dummy = ToneGenerator.empty(sampleRate: 44_100)

        var total: [Float] = []
        for _ in 0..<4 {
            let chunk = ToneGenerator.sine(frequency: 1_000, durationSec: 0.25, sampleRate: 44_100)
            total.append(contentsOf: try Resampler.resample(chunk, using: converter, flush: false))
        }
        total.append(contentsOf: try Resampler.resample(dummy, using: converter, flush: true))

        // 4 × 0.25 s = 1 s → ≈ 16_000 samples at 16 kHz
        let drift = abs(total.count - 16_000)
        #expect(drift <= 64, "drift was \(drift), total \(total.count)")
    }
}
