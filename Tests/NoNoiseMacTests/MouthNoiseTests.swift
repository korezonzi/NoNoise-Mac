import XCTest
@testable import Core

final class MouthNoiseTests: XCTestCase {

    // MARK: - DePlosive

    /// Disabled de-plosive is a perfect identity for arbitrary samples.
    func testDePlosiveDisabledIsIdentity() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99, -0.01] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-plosive must not alter samples")
        }
    }

    /// Below-threshold sub-bass is a perfect identity (quiet hum does not trigger).
    func testDePlosiveBelowThresholdIsIdentity() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            // 80 Hz sine at −54 dBFS (well below the −42 dB threshold)
            let x = 0.002 * sinf(2 * Float.pi * 80 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "below-threshold sub-bass must pass unchanged")
    }

    /// A loud, bottom-heavy low-band burst (simulating a P-pop) is attenuated.
    func testDePlosiveReducesLoudLowBandBurst() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var inSq: Float = 0, outSq: Float = 0
        let n = 9600, half = 2400   // measure 2nd half (settled detection)
        for i in 0..<n {
            // 60 Hz dominant + tiny 500 Hz harmonic → strong low-ratio bias
            let x = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / 48000)
                  + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            let y = d.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        let measured = n - half
        XCTAssertLessThan(sqrtf(outSq / Float(measured)),
                          sqrtf(inSq / Float(measured)) * 0.80,
                          "loud plosive-shaped signal must be attenuated by at least 2 dB")
    }

    /// Mid-frequency voiced content (500 Hz, loud) is NOT suppressed — the de-plosive
    /// must leave normal speech energy intact even when `enabled`.
    func testDePlosivePreservesMidBandVoice() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            // 500 Hz sine at 0.5 amplitude — clear speech energy, not a plosive
            let x = 0.5 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 0.05,
                          "mid-band voice must not be significantly altered by the de-plosive")
    }

    /// REGRESSION (state corruption): `DePlosive` must advance its internal high-pass
    /// EXACTLY ONCE per input sample. `Biquad.process` mutates filter state on every
    /// call, so a stray "peek" (e.g. `hp.process(0)`) would double-advance the filter
    /// and desync detection from output. We prove single-advance by reconstructing the
    /// same algorithm with our OWN single-advance high-pass and asserting byte-identical
    /// output on a plosive-triggering signal (if the production code double-advanced, its
    /// internal `lowSig` — and thus the subtracted output — would diverge from this
    /// one-pass reference).
    func testDePlosiveAdvancesFilterExactlyOncePerSample() {
        let splitHz: Float = 120, thrDb: Float = -42, guardRatio: Float = 0.60
        let maxRedDb: Float = 20, atkMs: Float = 0.3, relMs: Float = 25, sr: Float = 48000

        var d = DePlosive()
        d.configure(splitHz: splitHz, thresholdDb: thrDb, lowRatioGuard: guardRatio,
                    maxReductionDb: maxRedDb, attackMs: atkMs, releaseMs: relMs,
                    sampleRate: sr, enabled: true)

        // One-pass reference: mirror DePlosive.process with a single hp.process(x) per sample.
        var refHp = Biquad()
        refHp.setHighPass(freq: splitHz, sampleRate: sr, q: 0.707)
        let thrLin = powf(10, thrDb / 20)
        let maxRed = min(1, 1 - powf(10, -abs(maxRedDb) / 20))
        let atkC = expf(-1.0 / (max(atkMs, 0.01) * 0.001 * sr))
        let relC = expf(-1.0 / (max(relMs, 0.01) * 0.001 * sr))
        var refTotalEnv: Float = 0, refLowEnv: Float = 0

        var maxDelta: Float = 0
        for i in 0..<9600 {
            // Plosive-shaped: strong 60 Hz + weak 500 Hz → triggers the gate so the
            // subtractive branch (where any state desync would show up) is exercised.
            let x = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / sr)
                  + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / sr)

            let y = d.process(x)

            // Reference (single advance).
            let hiSig = refHp.process(x)
            let lowSig = x - hiSig
            let totalMag = abs(x), lowMag = abs(lowSig)
            let tC = totalMag > refTotalEnv ? atkC : relC
            let lC = lowMag   > refLowEnv   ? atkC : relC
            refTotalEnv = tC * refTotalEnv + (1 - tC) * totalMag
            refLowEnv   = lC * refLowEnv   + (1 - lC) * lowMag
            var ref = x
            if refTotalEnv > thrLin {
                let ratio = refLowEnv / max(refTotalEnv, 1e-12)
                if ratio >= guardRatio {
                    let over = refTotalEnv / thrLin
                    let frac = maxRed * (1 - 1 / over)
                    ref = x - frac * lowSig
                }
            }
            maxDelta = max(maxDelta, abs(y - ref))
        }
        XCTAssertLessThan(maxDelta, 1e-6,
                          "DePlosive must advance its high-pass exactly once per sample")
    }

    // MARK: - DeClick

    /// Disabled de-click is a perfect identity.
    func testDeClickDisabledIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-click must not alter samples")
        }
    }

    /// Steady speech (not a click) — ratio never trips — passes through unchanged.
    func testDeClickSteadySpeechIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Run a 200 Hz sine for 1 s so the slow background settles.
        var maxDelta: Float = 0
        let settleSamples = 48000
        for i in 0..<settleSamples {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            // Measure only after settling (second half)
            if i >= settleSamples / 2 {
                maxDelta = max(maxDelta, abs(y - x))
            }
        }
        XCTAssertLessThan(maxDelta, 0.01,
                          "steady speech must not be attenuated by the de-click")
    }

    /// A short spike (simulating a lip-smack) is attenuated while the steady
    /// background preceding/following it is untouched.
    func testDeClickReducesShortSpike() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Settle the slow background with quiet speech for 0.5 s
        for i in 0..<24000 {
            _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // Inject a single-sample spike at 10× background (well past clickRatio × slow)
        let spikeSample: Float = 0.5   // >> 6 × 0.05
        let spikeOut = d.process(spikeSample)
        // The output must be significantly below the input spike
        XCTAssertLessThan(abs(spikeOut), abs(spikeSample) * 0.7,
                          "de-click must attenuate a short spike above the ratio threshold")
    }

    /// After the spike, the hold-release window expires and `gain` returns to ≥ 0.95
    /// within 20 ms — proving the de-click does NOT color normal speech that follows.
    func testDeClickReleasesQuickly() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Settle background
        for i in 0..<24000 {
            _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // Spike
        _ = d.process(0.5)
        // 20 ms of silence (960 samples) — gain must recover
        let releaseWindow = 960
        var finalGain: Float = 0
        for _ in 0..<releaseWindow {
            let x: Float = 0.05
            let y = d.process(x)
            finalGain = y / x   // gain = out/in when in != 0
        }
        XCTAssertGreaterThan(finalGain, 0.95,
                             "de-click gain must recover to near-unity within 20 ms after spike")
    }

    /// IDENTITY AT REST (non-negotiable): a normal VOICED ONSET after silence must be
    /// EXACT identity — `out == in` for EVERY sample, with NO samples skipped. The gate
    /// must never arm from cold silence (no established background), so it cannot touch
    /// even the first sample of clean speech. A previous design skipped the first ~1 ms
    /// and only checked an RMS ratio > 0.97, which permitted attenuating the onset's first
    /// millisecond — a real identity violation. This asserts bit-level identity from
    /// sample 0 across the full onset.
    func testDeClickVoicedOnsetAfterSilenceIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // 200 ms of digital silence (slow background settles to ~0, like a real pause).
        for _ in 0..<9600 { _ = d.process(0) }
        // A voiced onset: a 200 Hz tone at speech level starting cold after the silence.
        // Every sample of the first 50 ms must be untouched — NO skipped samples.
        for i in 0..<2400 {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            XCTAssertEqual(y, x, accuracy: 1e-6,
                           "voiced onset after silence must be exact identity @\(i)")
        }
    }

    /// IDENTITY AT REST (non-negotiable, the realistic case): SPEECH → PAUSE → ONSET.
    /// After established speech ARMS the gate, a realistic short pause (~250 ms) must
    /// DISARM it so the NEXT clean voiced onset is again EXACT identity from sample 0.
    /// This is the case the cold-silence test never exercises: the disarm must be driven
    /// by ACTUAL instantaneous silence, NOT by the slow envelope. `slowEnv` releases over
    /// ~200 ms, so after speech it is STILL above the floor through a 250 ms pause — a
    /// slowEnv-based disarm would leave the gate ARMED and attenuate this onset (the round-4
    /// bug). The instantaneous-silence detector disarms after ~75 ms of silence, well inside
    /// the pause, so the onset re-arms cold and passes untouched.
    func testDeClickOnsetAfterSpeechThenPauseIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // 1) Establish speech long enough to ARM the gate (≥ warmupSamples ≈ 200 ms).
        //    Run 400 ms so the gate is unambiguously armed.
        for i in 0..<19200 {
            _ = d.process(0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // 2) A realistic 250 ms pause of digital silence. slowEnv (200 ms release) is STILL
        //    above the floor here, so a slowEnv-based disarm would NOT fire — but the
        //    instantaneous-silence detector disarms after ~75 ms.
        for _ in 0..<12000 { _ = d.process(0) }
        // 3) The next voiced onset must be EXACT identity for every sample of the first 50 ms.
        for i in 0..<2400 {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            XCTAssertEqual(y, x, accuracy: 1e-6,
                           "voiced onset after speech+pause must be exact identity @\(i)")
        }
    }

    /// REGRESSION (false positive): the steady VOICED BODY (sustained loud speech)
    /// must be a perfect passthrough — the click gate must never engage on it.
    func testDeClickVoicedBodyUntouched() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Loud sustained voiced tone for 1 s.
        var maxDelta: Float = 0
        let n = 48000
        for i in 0..<n {
            let x = 0.6 * sinf(2 * Float.pi * 220 * Float(i) / 48000)
            let y = d.process(x)
            if i >= n / 4 { maxDelta = max(maxDelta, abs(y - x)) }   // measure after settle
        }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "sustained voiced body must pass through the de-click unchanged")
    }

    // MARK: - MouthNoiseLevel

    func testMouthNoiseLevelOffIsZero() {
        XCTAssertEqual(MouthNoiseLevel.off.maxPlosReductionDb, 0)
        XCTAssertEqual(MouthNoiseLevel.off.clickGainFloor, 1.0, accuracy: 1e-6)
    }

    func testMouthNoiseLevelIsMonotonic() {
        XCTAssertLessThan(MouthNoiseLevel.low.maxPlosReductionDb,
                          MouthNoiseLevel.medium.maxPlosReductionDb)
        XCTAssertLessThan(MouthNoiseLevel.medium.maxPlosReductionDb,
                          MouthNoiseLevel.high.maxPlosReductionDb)
        XCTAssertGreaterThan(MouthNoiseLevel.low.clickGainFloor,
                             MouthNoiseLevel.medium.clickGainFloor)
        XCTAssertGreaterThan(MouthNoiseLevel.medium.clickGainFloor,
                             MouthNoiseLevel.high.clickGainFloor)
    }

    func testMouthNoiseLevelCasesAndLabels() {
        XCTAssertEqual(MouthNoiseLevel.allCases, [.off, .low, .medium, .high])
        XCTAssertEqual(MouthNoiseLevel.off.label, "Off")
        XCTAssertEqual(MouthNoiseLevel.high.label, "High")
    }

    func testMouthNoiseLevelHighCapped() {
        // High must not exceed 24 dB plosive reduction — aggressive defaults harm
        // voiced stops (B, D, G) that are NOT plosives.
        XCTAssertLessThanOrEqual(MouthNoiseLevel.high.maxPlosReductionDb, 24,
                                 "de-plosive must stay conservative to preserve voiced stops")
        // High gain floor must not go below −15 dB (= 0.177) — click suppression
        // this aggressive would also attenuate consonant bursts.
        XCTAssertGreaterThan(MouthNoiseLevel.high.clickGainFloor, 0.17,
                             "de-click floor must stay within safe range")
    }

    // MARK: - VoiceChain integration

    /// mouthNoise == .off + disabled chain == passthrough (regression guard).
    func testChainMouthNoiseOffIsPassthrough() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .off
        chain.configure(s)
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "off+off must not modify samples")
    }

    /// mouthNoise active with polish OFF still runs (de-plosive and de-click engage).
    func testMouthNoiseActiveWithPolishOff() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        XCTAssertTrue(chain.isActive)
    }

    /// IDENTITY AT REST (limiter must not run in mouth-noise-only mode): with polish and
    /// clarity OFF and mouthNoise = .high, a LOUD (> −1 dBFS) clean mid-band sine — NOT a
    /// click or plosive — must pass through unchanged in steady state. The de-plosive/
    /// de-click stages are attenuation-only and never raise level, so no limiter is needed;
    /// running the limiter here would clamp a loud clean sample purely because the feature
    /// is on (an identity violation). Probe at 1 kHz (above the 120 Hz plosive split) at
    /// 0.95 amplitude (≈ −0.45 dBFS, above the −1 dBFS ceiling). We measure the SETTLED
    /// second half: the de-click's sub-millisecond onset gate may briefly act on the cold
    /// start (legitimate), but once the background settles the loud steady tone must pass
    /// untouched — if the limiter were running it would clamp every sample above the ceiling.
    func testMouthNoiseOnlyPreservesLoudCleanSignal() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled   // polish OFF, clarity OFF
        s.mouthNoiseLevel = .high
        chain.configure(s)
        let n = 9600
        var buf = [Float](repeating: 0, count: n)
        for i in 0..<n { buf[i] = 0.95 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        let ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        var maxDelta: Float = 0
        for i in (n / 2)..<n { maxDelta = max(maxDelta, abs(buf[i] - ref[i])) }   // settled half
        XCTAssertLessThan(maxDelta, 1e-4,
                          "mouth-noise-only mode must not limit a loud clean non-artifact signal")
    }

    /// Higher level produces more reduction on a plosive-shaped signal (monotonic).
    func testHigherMouthNoiseLevelReducesMoreOnPlosive() {
        func plosiveRMS(_ level: MouthNoiseLevel) -> Float {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.mouthNoiseLevel = level
            chain.configure(s)
            // Plosive signal: strong 60 Hz + weak 500 Hz
            var buf = [Float](repeating: 0, count: 9600)
            for i in 0..<buf.count {
                buf[i] = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / 48000)
                       + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            }
            buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            var sq: Float = 0
            for i in 4800..<buf.count { sq += buf[i] * buf[i] }
            return sqrtf(sq / 4800)
        }
        // Higher level → more reduction → lower output RMS on a plosive-shaped signal
        XCTAssertGreaterThan(plosiveRMS(.low),  plosiveRMS(.medium))
        XCTAssertGreaterThan(plosiveRMS(.medium), plosiveRMS(.high))
    }

    /// Changing mouthNoiseLevel while the chain stays active must reset the mouth-noise
    /// stages — verified on the NEXT NON-SILENT sample (a silence-only probe passes even
    /// with stale state, because silence × a stale `DeClick.gain` is still silence and a
    /// stale plosive high-pass rings out in microseconds). We drive the chain with a
    /// click+plosive burst that engages BOTH stages (DeClick.gain → floor, plosive
    /// envelopes/HP charged), switch level, then feed a steady CLEAN probe and require it
    /// to equal a freshly-configured chain that never saw the burst. Any leftover
    /// `DeClick.gain < 1` (un-reset) would attenuate the probe and fail the match.
    func testMouthNoiseLevelChangeResetsStages() {
        func freshProbeOutput(_ level: MouthNoiseLevel) -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.mouthNoiseLevel = level
            chain.configure(s)
            // Clean, steady, non-silent probe (no artifact) — identity at rest under mouth-noise-only.
            var probe = [Float](repeating: 0, count: 256)
            for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
            probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return probe
        }

        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Energize BOTH stages: a low-band plosive bias + a hard click transient.
        var burst = [Float](repeating: 0, count: 4800)
        for i in 0..<burst.count {
            burst[i] = 0.9 * sinf(2 * Float.pi * 60 * Float(i) / 48000)
        }
        burst[2400] = 0.99   // sharp click → drives DeClick.gain toward the floor
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        // Switch level while still active → must reset DePlosive + DeClick.
        s.mouthNoiseLevel = .low
        chain.configure(s)

        // Probe with a clean steady signal; compare to a chain that never saw the burst.
        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let fresh = freshProbeOutput(.low)
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - fresh[i])) }
        XCTAssertLessThan(maxDelta, 1e-5,
                          "mouth-noise stages must fully reset on level change — no stale gain/state")
    }

    /// REGRESSION (bumpless carry-state contract): reconfiguring on an UNRELATED setting
    /// change (here, `clarity`) while `mouthNoiseLevel` stays the SAME must NOT cold-reset
    /// the mouth-noise detector state. `VoiceChain.configure` only calls `deClick.reset()` /
    /// `dePlosive.reset()` when `mouthNoiseLevel` itself changes; and `DeClick.configure(enabled:
    /// true)` (mirroring `DeEsser`) updates coefficients only — it must not clear runtime state.
    /// We energize the de-click (drive its gain below unity near the end of a burst), then
    /// reconfigure with the SAME mouthNoise but a CHANGED clarity, and require the next probe
    /// to DIFFER from a freshly-cold chain. If either layer wrongly cleared state, the carried
    /// chain would equal the cold chain (a cold-restart of mouth-noise on an unrelated change).
    func testUnrelatedConfigChangeDoesNotResetMouthNoise() {
        // Reference: a chain that has NEVER seen the burst (cold mouth-noise state),
        // configured at the post-change settings (clarity .low, mouthNoise .high).
        func coldChain() -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.clarity = .low
            s.mouthNoiseLevel = .high
            chain.configure(s)
            var probe = [Float](repeating: 0, count: 256)
            for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
            probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return probe
        }

        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.clarity = .off            // clarity starts OFF
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Establish a background, then a hard click near the END so the de-click gain is
        // still below unity (mid hold/release) when the burst finishes.
        var burst = [Float](repeating: 0, count: 12000)   // 250 ms ≥ warmup → gate armed
        for i in 0..<burst.count { burst[i] = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000) }
        burst[11990] = 0.99   // sharp click at the very end → gain driven toward the floor
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        // Change ONLY clarity (.off → .low); mouthNoise stays .high → mouth-noise must NOT reset.
        s.clarity = .low
        chain.configure(s)

        // Probe: a clean steady signal. The CARRIED de-click (armed, gain mid-release, slowEnv
        // charged) shapes the first samples differently than a cold chain would.
        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let cold = coldChain()
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - cold[i])) }
        XCTAssertGreaterThan(maxDelta, 1e-4,
                             "unrelated config change must NOT cold-reset mouth-noise state (state must carry)")
    }

    /// A simultaneous clarity + mouthNoise level change (while the chain stays active) must
    /// reset BOTH stage groups, not just one. The level-change reset uses INDEPENDENT `if`
    /// checks (not `else if`), so a single configure call that changes both clarity and
    /// mouthNoise resets clarity AND mouth-noise. Probe on the next non-silent sample.
    func testSimultaneousClarityAndMouthNoiseChangeResetsBoth() {
        // Reference: a fresh chain configured directly at the target levels.
        func freshOutput() -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.clarity = .low
            s.mouthNoiseLevel = .low
            chain.configure(s)
            var probe = [Float](repeating: 0, count: 256)
            for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
            probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return probe
        }

        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.clarity = .high
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Energize clarity (sibilant burst) AND mouth-noise (plosive + click) stages.
        var burst = [Float](repeating: 0, count: 4800)
        for i in 0..<burst.count {
            burst[i] = 0.9 * sinf(2 * Float.pi * 60 * Float(i) / 48000)
                     + 0.4 * sinf(2 * Float.pi * 7000 * Float(i) / 48000)
        }
        burst[2400] = 0.99
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        // Change BOTH levels in one configure call.
        s.clarity = .low
        s.mouthNoiseLevel = .low
        chain.configure(s)

        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let fresh = freshOutput()
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - fresh[i])) }
        XCTAssertLessThan(maxDelta, 1e-5,
                          "simultaneous clarity+mouthNoise change must reset both stage groups")
    }

    /// mouthNoise == .off with an enabled (polish-on) preset must be bit-identical
    /// to the chain without the mouth-noise stages — proving Off is a true no-op.
    func testMouthNoiseOffMatchesLegacyChain() {
        // Use podcast preset — polish ON, mouthNoiseLevel defaults to .off.
        let s = VoicePreset.podcast.voiceChain
        XCTAssertEqual(s.mouthNoiseLevel, .off,
                       "preset voiceChain must default mouthNoiseLevel to .off")
        let chain = VoiceChain()
        chain.configure(s)

        // Reference: canonical chain without de-plosive/de-click stages.
        var hp = Biquad(), lo = Biquad(), hi = Biquad(), pres = Biquad()
        var deEss = DeEsser()
        var comp = Compressor(); var lim = Limiter()
        hp.setHighPass(freq: s.highPassHz, sampleRate: 48000)
        lo.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: 48000)
        hi.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: 48000)
        // clarity is .off on the podcast preset (Broadcast Voice is orthogonal)
        pres.setBypass()
        deEss.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 0,
                        attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: false)
        comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio,
                       attackMs: s.compAttackMs, releaseMs: s.compReleaseMs,
                       makeupDb: s.compMakeupDb, sampleRate: 48000)
        lim.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: 48000)

        var buf = [Float](repeating: 0, count: 4800)
        for i in 0..<buf.count { buf[i] = 0.3 * sinf(2 * Float.pi * 220 * Float(i) / 48000) }
        var ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        for i in 0..<ref.count {
            var x = ref[i]
            x = hp.process(x); x = lo.process(x); x = hi.process(x)
            x = pres.process(x); x = deEss.process(x)
            x = comp.process(x); x = lim.process(x)
            ref[i] = x
        }
        for i in 0..<buf.count {
            XCTAssertEqual(buf[i], ref[i], accuracy: 1e-6,
                           "mouthNoise Off must equal canonical chain @\(i)")
        }
    }
}
