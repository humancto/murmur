import AVFoundation

/// Programmatic, deterministic PCM buffer factory for tests. Avoids
/// committing fixture WAV files; every test input is reconstructible
/// from primitives.
enum ToneGenerator {

    /// Build a non-interleaved float32 PCM buffer containing `durationSec`
    /// of a sine wave at `frequency` Hz, sampled at `sampleRate`.
    /// Each output channel carries the same waveform (mono content
    /// duplicated for stereo).
    static func sine(
        frequency: Double,
        durationSec: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount = 1,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(durationSec * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return buffer }
        let twoPiF = 2 * Double.pi * frequency
        for ch in 0..<Int(channels) {
            let ptr = channelData[ch]
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                ptr[i] = amplitude * Float(sin(twoPiF * t))
            }
        }
        return buffer
    }

    /// Empty (zero-frame) buffer in the given format. Useful for
    /// flush-only test cases.
    static func empty(sampleRate: Double, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 0
        return buffer
    }

    /// Compute root-mean-square over the first channel of a buffer.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sumSq: Double = 0
        let ptr = data[0]
        for i in 0..<n { sumSq += Double(ptr[i] * ptr[i]) }
        return Float((sumSq / Double(n)).squareRoot())
    }

    /// Compute RMS over a `[Float]` array.
    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s * s) }
        return Float((sumSq / Double(samples.count)).squareRoot())
    }
}
