import Foundation
import Testing
import MurmurCore

@Suite("VAD")
struct VADTests {

    /// Build a contiguous Float buffer at `sampleRate` Hz. `silenceDurationsMs`
    /// alternates with `toneDurationsMs` starting with silence.
    private func interleave(
        sampleRate: Double,
        silenceDurationsMs: [Double],
        toneDurationsMs: [Double],
        toneFrequency: Double = 1_000,
        amplitude: Float = 0.5
    ) -> [Float] {
        var out: [Float] = []
        let twoPiF = 2 * Double.pi * toneFrequency
        var phase = 0.0
        var sIdx = 0
        var tIdx = 0
        var phaseSilenceFirst = true

        while sIdx < silenceDurationsMs.count || tIdx < toneDurationsMs.count {
            if phaseSilenceFirst, sIdx < silenceDurationsMs.count {
                let n = Int(silenceDurationsMs[sIdx] * sampleRate / 1000)
                out.append(contentsOf: Array(repeating: Float(0), count: n))
                sIdx += 1
            } else if tIdx < toneDurationsMs.count {
                let n = Int(toneDurationsMs[tIdx] * sampleRate / 1000)
                for _ in 0..<n {
                    out.append(amplitude * Float(sin(phase)))
                    phase += twoPiF / sampleRate
                }
                tIdx += 1
            }
            phaseSilenceFirst.toggle()
        }
        return out
    }

    private func tone(durationMs: Double, sampleRate: Double = 16_000, amplitude: Float = 0.5) -> [Float] {
        let n = Int(durationMs * sampleRate / 1000)
        var out: [Float] = []
        out.reserveCapacity(n)
        let twoPiF = 2 * Double.pi * 1_000
        for i in 0..<n {
            out.append(amplitude * Float(sin(twoPiF * Double(i) / sampleRate)))
        }
        return out
    }

    private func silence(durationMs: Double, sampleRate: Double = 16_000) -> [Float] {
        Array(repeating: Float(0), count: Int(durationMs * sampleRate / 1000))
    }

    @Test("empty input returns empty")
    func emptyReturnsEmpty() {
        #expect(VAD().trim([]).isEmpty)
    }

    @Test("pure silence returns empty")
    func pureSilenceReturnsEmpty() {
        let samples = silence(durationMs: 1_000)
        #expect(VAD().trim(samples).isEmpty)
    }

    @Test("pure tone is preserved (within ±1 window)")
    func pureToneIsPreserved() {
        // 1 s of audible tone. With leading/trailing pad clamps at the
        // buffer edges, output should be ≈ input length.
        let samples = tone(durationMs: 1_000)
        let trimmed = VAD().trim(samples)
        #expect(!trimmed.isEmpty)
        // ±1 window (480 samples at 16 kHz) tolerance for window-aligned detection
        #expect(abs(trimmed.count - samples.count) <= 480, "trimmed=\(trimmed.count), input=\(samples.count)")
    }

    @Test("silence-tone-silence trims to ~tone + pads")
    func silenceToneSilenceTrimsCorrectly() {
        // 500 ms silence + 500 ms tone + 500 ms silence
        let samples = silence(durationMs: 500) + tone(durationMs: 500) + silence(durationMs: 500)
        let trimmed = VAD().trim(samples)
        // Expected: ~500 ms tone + 100 ms leading pad + 200 ms trailing pad ≈ 800 ms
        let expectedSamples = Int(0.8 * 16_000)
        #expect(abs(trimmed.count - expectedSamples) <= 480 * 2,
                "trimmed=\(trimmed.count), expected~\(expectedSamples)")
        #expect(trimmed.count < samples.count, "trim should shorten the buffer")
    }

    @Test("intra-speech silence is preserved")
    func intraSpeechSilenceIsPreserved() {
        // 300 ms tone + 400 ms silence + 300 ms tone (total 1.0 s, no leading/trailing silence)
        let samples = tone(durationMs: 300) + silence(durationMs: 400) + tone(durationMs: 300)
        let trimmed = VAD().trim(samples)
        // We expect the entire buffer back (plus pad clamps) — intra-speech
        // gap is NOT trimmed. With 100/200 ms pads but starting near sample 0,
        // leading pad clamps to 0; trailing pad clamps near the end.
        #expect(!trimmed.isEmpty)
        // Output should be ≈ input length within tolerance
        #expect(abs(trimmed.count - samples.count) <= 480 * 2, "trimmed=\(trimmed.count), input=\(samples.count)")
    }

    @Test("speech below minSpeechMs returns empty")
    func subMinimumSpeechReturnsEmpty() {
        // 50 ms tone — well below default minSpeechMs (100 ms)
        let samples = silence(durationMs: 200) + tone(durationMs: 50) + silence(durationMs: 200)
        let trimmed = VAD().trim(samples)
        #expect(trimmed.isEmpty, "50 ms speech should be below 100 ms minimum, got \(trimmed.count) samples")
    }

    @Test("threshold tuning changes detection behavior")
    func thresholdAffectsDetection() {
        // Tone at amplitude 0.01 → ≈ -40 dBFS RMS for a sinusoid
        // (RMS of sin = amplitude/√2; -40 dBFS ≈ amplitude ≈ 0.014).
        // At amplitude 0.005 (≈ -52 dBFS), default -40 misses it but -55 catches it.
        let samples = silence(durationMs: 200) + tone(durationMs: 500, amplitude: 0.005) + silence(durationMs: 200)

        let strict = VAD(config: .init(energyThresholdDBFS: -40))
        let permissive = VAD(config: .init(energyThresholdDBFS: -55))

        // Strict should miss this quiet tone entirely
        #expect(strict.trim(samples).isEmpty,
                "strict (-40 dBFS) should reject -52 dBFS tone")
        // Permissive should catch it
        #expect(!permissive.trim(samples).isEmpty,
                "permissive (-55 dBFS) should detect -52 dBFS tone")
    }

    /// Apple-expert must-fix #2: explicit edge case for "exactly one speech
    /// window detected → empty". Confirms the off-by-one on
    /// `lastSpeech = windowStart + windowSize` produces correct
    /// `speechDurationMs` math (one 30 ms window < 100 ms minSpeechMs).
    @Test("exactly one speech window detected returns empty (under minSpeechMs)")
    func exactlyOneWindowReturnsEmpty() {
        // 30 ms tone embedded in silence — exactly one 30 ms window of speech.
        // 30 ms < default 100 ms minSpeechMs → should return [].
        let samples = silence(durationMs: 200) + tone(durationMs: 30) + silence(durationMs: 200)
        let trimmed = VAD().trim(samples)
        #expect(trimmed.isEmpty,
                "single 30 ms window should fall below 100 ms minSpeechMs, got \(trimmed.count) samples")
    }
}
