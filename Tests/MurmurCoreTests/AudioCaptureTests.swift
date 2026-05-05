import Foundation
import Testing
import MurmurCore

@Suite("AudioCapture")
struct AudioCaptureTests {

    /// Hardware-mic test gate. Set `MURMUR_SKIP_AUDIO_HARDWARE=1` in CI or
    /// any environment without a physical microphone to skip the smoke test.
    static var shouldSkipHardware: Bool {
        ProcessInfo.processInfo.environment["MURMUR_SKIP_AUDIO_HARDWARE"] != nil
    }

    @Test("stop without start returns empty samples and didCap=false")
    func stopWithoutStartReturnsEmpty() async {
        let capture = AudioCapture()
        let result = await capture.stop()
        #expect(result.samples.isEmpty)
        #expect(result.didCap == false)
    }

    @Test("isCapturing is false initially")
    func isCapturingIsFalseInitially() async {
        let capture = AudioCapture()
        let isCapturing = await capture.isCapturing
        #expect(isCapturing == false)
    }

    @Test(
        "start then immediate stop returns a result tuple",
        .disabled(if: AudioCaptureTests.shouldSkipHardware,
                  "MURMUR_SKIP_AUDIO_HARDWARE is set")
    )
    func startThenStopReturnsTuple() async throws {
        let capture = AudioCapture()
        try await capture.start()
        // Don't sleep — we don't care what samples are captured. We only
        // care that the engine boots, the tap installs, and stop() returns
        // the tuple shape without throwing.
        let result = await capture.stop()
        // Length is non-deterministic (depends on audio thread scheduling).
        // didCap should not have fired in this short window.
        #expect(result.didCap == false)
        let isCapturing = await capture.isCapturing
        #expect(isCapturing == false)
        _ = result.samples  // touch to silence unused-result warnings
    }
}
