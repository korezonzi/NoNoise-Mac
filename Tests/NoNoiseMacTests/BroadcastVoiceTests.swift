import XCTest
@testable import Core

final class BroadcastVoiceTests: XCTestCase {

    // MARK: - Biquad peaking (presence bell)

    /// A peaking bell must leave DC (and thus the low-frequency vocal body) at unity gain.
    func testPeakingHasUnityDCGain() {
        var b = Biquad()
        b.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000, q: 0.7)
        XCTAssertEqual(b.dcGain, 1.0, accuracy: 1e-3, "presence bell must not change DC/low end")
    }

    /// At the center frequency, a +6 dB bell must audibly boost (output RMS > input RMS).
    func testPeakingBoostsCenterFrequency() {
        var b = Biquad()
        b.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000, q: 0.7)
        let inRMS = sineRMS(freq: 4500, amp: 0.3, n: 9600, through: &b)
        XCTAssertGreaterThan(inRMS.outRMS / inRMS.inRMS, 1.3, "center frequency must be lifted")
    }

    /// A low tone (vocal body) must pass a presence bell ~unchanged — identity of the voice.
    func testPeakingPreservesLowEnd() {
        var b = Biquad()
        b.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000, q: 0.7)
        let r = sineRMS(freq: 180, amp: 0.3, n: 9600, through: &b)
        XCTAssertEqual(r.outRMS / r.inRMS, 1.0, accuracy: 0.05, "low end must be essentially untouched")
    }

    // MARK: - Helpers

    /// Drive a steady sine through a biquad; return input/steady-state output RMS
    /// (measured over the second half to skip the filter's settling transient).
    private func sineRMS(freq: Float, amp: Float, n: Int, through b: inout Biquad)
        -> (inRMS: Float, outRMS: Float) {
        var inSq: Float = 0, outSq: Float = 0
        let half = n / 2
        for i in 0..<n {
            let x = amp * sinf(2 * Float.pi * freq * Float(i) / 48000)
            let y = b.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        let denom = Float(n - half)
        return (sqrtf(inSq / denom), sqrtf(outSq / denom))
    }
}
