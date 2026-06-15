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

    // MARK: - DeEsser

    /// Disabled de-esser is a perfect identity for any sample.
    func testDeEsserDisabledIsIdentity() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 6,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7, "disabled de-esser must not alter samples")
        }
    }

    /// Quiet sibilance (below threshold) passes through unchanged — voice stays original.
    func testDeEsserQuietSibilancePasses() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 6,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            let x = 0.02 * sinf(2 * Float.pi * 7000 * Float(i) / 48000) // ~ -34 dB, below -28 dB
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-4, "below-threshold sibilance must pass unchanged")
    }

    /// Loud sibilance is reduced (output high-band energy < input).
    /// Probe at 10 kHz: representative of real "ess" sibilance and far enough above the
    /// 6 kHz crossover that the subtractive band (`out = x − frac·sib`) is near-in-phase,
    /// so the reduction is genuine. (A tone just above the crossover — e.g. 7.5 kHz — sees
    /// a ~70° high-pass phase shift that mathematically caps subtractive cancellation near
    /// ~6 %, so it cannot probe real attenuation regardless of `maxReductionDb`.)
    func testDeEsserReducesLoudSibilance() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 8,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: true)
        var inSq: Float = 0, outSq: Float = 0
        let n = 9600, half = 4800
        for i in 0..<n {
            let x = 0.8 * sinf(2 * Float.pi * 10000 * Float(i) / 48000) // loud, well above threshold
            let y = d.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        XCTAssertLessThan(sqrtf(outSq / Float(half)), sqrtf(inSq / Float(half)) * 0.85,
                          "loud sibilance must be attenuated")
    }

    /// Loud LOW-frequency content (vocal body) is untouched even with the de-esser ON.
    func testDeEsserPreservesVoiceBody() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 8,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            let x = 0.8 * sinf(2 * Float.pi * 200 * Float(i) / 48000) // loud, but below the sib band
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-3, "the de-esser must not touch the vocal body")
    }

    // MARK: - ClarityLevel

    func testClarityOffIsZero() {
        XCTAssertEqual(ClarityLevel.off.presenceDb, 0)
        XCTAssertEqual(ClarityLevel.off.deEssMaxReductionDb, 0)
    }

    func testClarityLevelsAreMonotonic() {
        XCTAssertLessThan(ClarityLevel.low.presenceDb, ClarityLevel.medium.presenceDb)
        XCTAssertLessThan(ClarityLevel.medium.presenceDb, ClarityLevel.high.presenceDb)
        XCTAssertLessThan(ClarityLevel.low.deEssMaxReductionDb, ClarityLevel.medium.deEssMaxReductionDb)
        XCTAssertLessThan(ClarityLevel.medium.deEssMaxReductionDb, ClarityLevel.high.deEssMaxReductionDb)
    }

    func testClarityCasesAndLabels() {
        XCTAssertEqual(ClarityLevel.allCases, [.off, .low, .medium, .high])
        XCTAssertEqual(ClarityLevel.off.label, "Off")
        XCTAssertEqual(ClarityLevel.high.label, "High")
    }

    /// Presence is capped even at High — clarity must never become an aggressive EQ.
    func testClarityPresenceIsConservativelyCapped() {
        XCTAssertLessThanOrEqual(ClarityLevel.high.presenceDb, 5,
                                 "presence lift stays gentle to preserve the original voice")
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
