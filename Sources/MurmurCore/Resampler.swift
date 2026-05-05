@preconcurrency public import AVFoundation

/// Stateless namespace that converts `AVAudioPCMBuffer` chunks into
/// Whisper-compatible `[Float]` samples (16 kHz mono float32).
///
/// The caller owns the `AVAudioConverter` and must reuse the same
/// instance across every chunk of a capture so that the converter's
/// streaming filter state is preserved. After the last input chunk,
/// call once more with a zero-frame buffer and `flush: true` to
/// drain the converter's internal tail.
public enum Resampler {

    /// Whisper's required input format: 16 kHz mono PCM float32, non-interleaved.
    /// Force-unwrap is justified — this combination is valid on every Apple
    /// platform Murmur targets (macOS 14+, future iOS port).
    public static let whisperTarget = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Run one chunk through a caller-provided converter.
    ///
    /// - Parameters:
    ///   - input: A PCM buffer in the converter's input format. Pass a
    ///     zero-frame buffer when only flushing.
    ///   - converter: Long-lived converter created at capture start.
    ///     The same instance must be passed across all chunks of a
    ///     capture to preserve filter state.
    ///   - flush: `true` on the final call to drain the converter's
    ///     internal tail and signal end-of-stream.
    /// - Returns: Resampled mono float32 samples at the converter's
    ///   output sample rate.
    public static func resample(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        flush: Bool = false
    ) throws -> [Float] {
        if input.frameLength == 0 && !flush { return [] }

        // Output capacity scales by sample-rate ratio; flushing needs
        // extra headroom for the converter's filter tail (group delay
        // can be tens of frames at high quality). 1 s of slack at the
        // target rate is cheap and bullet-proof.
        let target = converter.outputFormat
        let ratio = target.sampleRate / input.format.sampleRate
        let baseCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        let outCapacity = flush
            ? baseCapacity + AVAudioFrameCount(target.sampleRate)
            : baseCapacity

        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(outCapacity, 1)) else {
            throw ResamplerError.outputBufferAllocationFailed
        }

        // The conversion callback is `@Sendable`. We need single-shot
        // "have we fed yet" state, which a captured `var` can't provide.
        // Class-based reference holder is the documented escape hatch.
        final class FedFlag: @unchecked Sendable { var fed = false }
        let flag = FedFlag()

        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if flush && (input.frameLength == 0 || flag.fed) {
                statusPtr.pointee = .endOfStream
                return nil
            }
            if !flag.fed {
                flag.fed = true
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
