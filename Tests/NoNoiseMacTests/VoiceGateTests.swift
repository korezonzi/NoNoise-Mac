import XCTest
@testable import Core

private let sr: Float = 48000

/// A steady 200 Hz sine at the given dBFS level, `seconds` long at 48 kHz.
private func tone(dbfs: Float, seconds: Float) -> [Float] {
    let amp = powf(10, dbfs / 20)
    let count = Int(seconds * sr)
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count { out[i] = amp * sinf(2 * Float.pi * 200 * Float(i) / sr) }
    return out
}

/// Per-window (default 10 ms) peak(output)/peak(input) ratio — a bumpless-friendly way to
/// read the gate's applied gain without dividing by near-zero samples at sine zero-crossings.
private func windowedPeakRatios(x: ArraySlice<Float>, y: ArraySlice<Float>, windowMs: Float = 10) -> [Float] {
    let windowSize = Int(windowMs * 0.001 * sr)
    let xs = Array(x), ys = Array(y)
    var ratios: [Float] = []
    var i = 0
    while i + windowSize <= xs.count {
        var xPeak: Float = 0, yPeak: Float = 0
        for j in i..<(i + windowSize) {
            xPeak = max(xPeak, abs(xs[j]))
            yPeak = max(yPeak, abs(ys[j]))
        }
        ratios.append(xPeak > 1e-9 ? yPeak / xPeak : 1)
        i += windowSize
    }
    return ratios
}

final class VoiceGateTests: XCTestCase {

    /// Configure `g` from a `VoiceGateLevel`'s own params + the fixed `VoiceGateProfile` inner
    /// time constants — the exact call `VoiceChain.configure` makes. Shared so every test
    /// reconfigures identically to production, whether building fresh or re-configuring in place.
    private func reconfigure(_ g: inout VoiceGate, level: VoiceGateLevel, enabled: Bool? = nil) {
        g.configure(marginDb: level.marginDb, absoluteFloorDb: level.absoluteFloorDb,
                    hysteresisDb: level.hysteresisDb, floorDb: level.floorDb,
                    attackMs: VoiceGateProfile.attackMs, holdMs: level.holdMs,
                    releaseMs: VoiceGateProfile.releaseMs,
                    envAttackMs: VoiceGateProfile.envAttackMs, envReleaseMs: VoiceGateProfile.envReleaseMs,
                    peakAttackMs: VoiceGateProfile.peakAttackMs, peakReleaseMs: VoiceGateProfile.peakReleaseMs,
                    sampleRate: sr, enabled: enabled ?? (level != .off))
    }

    private func makeGate(level: VoiceGateLevel) -> VoiceGate {
        var g = VoiceGate()
        reconfigure(&g, level: level)
        return g
    }

    // MARK: - 1. Off / disabled is identity

    func testOffIsIdentity() {
        var g = makeGate(level: .off)
        for x in [Float(0), 0.5, -0.73, 0.99] {
            XCTAssertEqual(g.process(x), x, accuracy: 1e-7, "disabled gate must not alter samples")
        }
    }

    // MARK: - 2. Loud tone opens and stays open

    func testHighLevelOpensForLoudTone() {
        var g = makeGate(level: .high)
        let x = tone(dbfs: -12, seconds: 1)
        let startIdx = Int(0.1 * sr)
        for i in 0..<x.count {
            let y = g.process(x[i])
            if i >= startIdx && abs(x[i]) > 0.1 {
                XCTAssertGreaterThanOrEqual(abs(y) / abs(x[i]), 0.99, "sample \(i) must be near-unity once open")
            }
        }
    }

    // MARK: - 3. Quiet tail closes to the level's floor

    func testHighLevelClosesForQuietTail() {
        var g = makeGate(level: .high)
        let loud = tone(dbfs: -12, seconds: 1)
        let quiet = tone(dbfs: -46, seconds: 1)
        for x in loud { _ = g.process(x) }

        var ys = [Float](repeating: 0, count: quiet.count)
        for i in 0..<quiet.count { ys[i] = g.process(quiet[i]) }

        let windowSize = Int(0.01 * sr)
        // Settling: envDb needs ~90 ms to fall below the close threshold, then holdMs (150 ms)
        // elapses before the gate actually closes, and ONLY THEN does the dB-domain gain smoother
        // start its one-pole approach toward the -60 dB floor. Because the smoothing runs IN DB
        // (mirrors Compressor.envDb), the release rate is a constant dB/s regardless of floor
        // depth — reaching within 3 dB of -60 dB needs ~3 releaseMs (60 ms) time constants, i.e.
        // ~180 ms after closing. Total ≈ 90 + 150 + 180 = ~420 ms. Verified by simulation: the
        // combined output is within 3 dB of the floor from ~420 ms onward, so 600 ms gives a
        // safe margin.
        let startIdx = Int(0.6 * sr)
        let expectedFloorDb: Float = -46 - 60   // input level + high's floorDb
        var i = startIdx
        while i + windowSize <= ys.count {
            var peak: Float = 0
            for j in i..<(i + windowSize) { peak = max(peak, abs(ys[j])) }
            let peakDb = 20 * log10f(max(peak, 1e-9))
            XCTAssertEqual(peakDb, expectedFloorDb, accuracy: 3,
                          "closed-gate output must settle near the expected floor @\(i)")
            i += windowSize
        }
    }

    // MARK: - 4. Level difference: low stays open, high closes

    func testLowLevelStaysOpenHighLevelCloses() {
        let loud = tone(dbfs: -12, seconds: 1)
        let quiet = tone(dbfs: -27, seconds: 1)

        var low = makeGate(level: .low)
        for x in loud { _ = low.process(x) }
        var lowYs = [Float](repeating: 0, count: quiet.count)
        for i in 0..<quiet.count { lowYs[i] = low.process(quiet[i]) }
        let lowRatios = windowedPeakRatios(x: quiet[...], y: lowYs[...])
        XCTAssertTrue(lowRatios.allSatisfy { $0 >= 0.9 },
                     "low must stay open on -27 dBFS after loud speech (above its close threshold -30)")

        var high = makeGate(level: .high)
        for x in loud { _ = high.process(x) }
        var highYs = [Float](repeating: 0, count: quiet.count)
        for i in 0..<quiet.count { highYs[i] = high.process(quiet[i]) }
        // Gain crosses the 0.01 (-40 dB) mark around 300-320 ms (hold 150 ms + the dB-domain
        // one-pole release only needs to clear -40 dB here, well before it nears the -60 dB
        // target); 600 ms gives a safe margin (verified by simulation).
        let idx600 = Int(0.6 * sr)
        let highRatios = windowedPeakRatios(x: quiet[idx600...], y: highYs[idx600...])
        XCTAssertTrue(highRatios.allSatisfy { $0 <= 0.01 },
                     "high must close on -27 dBFS after loud speech (below its close threshold -22)")
    }

    // MARK: - 5. Hold bridges a short silence gap

    func testHoldBridgesShortGap() {
        var g = makeGate(level: .high)   // holdMs 150
        let loud1 = tone(dbfs: -12, seconds: 0.5)
        for x in loud1 { _ = g.process(x) }

        let gapSamples = Int(0.1 * sr)   // 100 ms, shorter than holdMs (150 ms)
        for _ in 0..<gapSamples { _ = g.process(0) }

        let loud2 = tone(dbfs: -12, seconds: 0.05)
        let probeSamples = Int(0.005 * sr)   // first 5 ms
        for i in 0..<loud2.count {
            let y = g.process(loud2[i])
            if i < probeSamples {
                XCTAssertGreaterThanOrEqual(abs(y), 0.95 * abs(loud2[i]),
                                            "gate must still be held open right after a sub-hold gap @\(i)")
            }
        }
    }

    // MARK: - 6. Absolute floor governs a fresh (unlearned) gate

    func testAbsoluteFloorOnFreshGate() {
        var gOpens = makeGate(level: .high)
        let toneOpens = tone(dbfs: -30, seconds: 1)
        var ysOpens = [Float](repeating: 0, count: toneOpens.count)
        for i in 0..<toneOpens.count { ysOpens[i] = gOpens.process(toneOpens[i]) }
        let idx100 = Int(0.1 * sr)
        let ratiosOpens = windowedPeakRatios(x: toneOpens[idx100...], y: ysOpens[idx100...])
        XCTAssertTrue(ratiosOpens.allSatisfy { $0 >= 0.99 },
                     "-30 dBFS must open a fresh gate (above the absolute floor)")

        var gStays = makeGate(level: .high)
        let toneStays = tone(dbfs: -50, seconds: 1)
        var ysStays = [Float](repeating: 0, count: toneStays.count)
        for i in 0..<toneStays.count { ysStays[i] = gStays.process(toneStays[i]) }
        let idx400 = Int(0.4 * sr)
        let ratiosStays = windowedPeakRatios(x: toneStays[idx400...], y: ysStays[idx400...])
        XCTAssertTrue(ratiosStays.allSatisfy { $0 <= 0.01 },
                     "-50 dBFS must stay closed on a fresh gate (below the absolute floor)")
    }

    // MARK: - 7. reset() restores fresh-gate behavior

    func testResetRestoresFreshGateBehavior() {
        var g = makeGate(level: .high)
        let loud = tone(dbfs: -12, seconds: 1)
        for x in loud { _ = g.process(x) }   // learn a high peak level

        g.reset()

        let toneStays = tone(dbfs: -50, seconds: 1)
        var ys = [Float](repeating: 0, count: toneStays.count)
        for i in 0..<toneStays.count { ys[i] = g.process(toneStays[i]) }
        let idx400 = Int(0.4 * sr)
        let ratios = windowedPeakRatios(x: toneStays[idx400...], y: ys[idx400...])
        XCTAssertTrue(ratios.allSatisfy { $0 <= 0.01 },
                     "reset() must clear the learned peak so a fresh -50 dBFS tone stays closed")
    }

    // MARK: - Carry-state contract: configure(enabled: true) never clears runtime state

    /// A same-params reconfigure while enabled (mirrors `DeEsser`/`DePlosive`/`DeClick`'s
    /// carry-state contract) must NOT clear `peakDb`/`env`/`state`/`gainDb`: the learned peak
    /// from the loud passage must survive the second `configure` call.
    func testReconfigureWithSameParamsPreservesLearnedPeak() {
        var g = makeGate(level: .high)
        let loud = tone(dbfs: -12, seconds: 1)
        for x in loud { _ = g.process(x) }   // learn a high peak level

        reconfigure(&g, level: .high)   // same params, still enabled — must be a no-op on state

        // -33 dBFS discriminates the two outcomes: with the LEARNED peak (-12 dBFS → open -18 /
        // close -22) it sits below the close threshold and the gate must close; on a FRESH gate
        // (open threshold = absolute floor -36) it would OPEN. So a reconfigure that wrongly
        // cleared `peakDb` fails this test instead of passing by accident.
        let quiet = tone(dbfs: -33, seconds: 1)
        var ys = [Float](repeating: 0, count: quiet.count)
        for i in 0..<quiet.count { ys[i] = g.process(quiet[i]) }
        let idx600 = Int(0.6 * sr)
        let ratios = windowedPeakRatios(x: quiet[idx600...], y: ys[idx600...])
        XCTAssertTrue(ratios.allSatisfy { $0 <= 0.01 },
                     "a same-params reconfigure must preserve the learned peak so -33 dBFS still closes")
    }

    /// `configure(enabled: false)` followed by `configure(enabled: true)` — the disabled arm
    /// (which calls `reset()`) followed by a fresh enable — must behave exactly like a brand-new,
    /// unlearned gate: a -30 dBFS tone opens it purely via the absolute floor.
    func testDisableThenEnableActsLikeFreshGate() {
        var g = makeGate(level: .high)
        let loud = tone(dbfs: -12, seconds: 1)
        for x in loud { _ = g.process(x) }   // learn a high peak level

        reconfigure(&g, level: .high, enabled: false)   // disabled arm → reset()
        reconfigure(&g, level: .high, enabled: true)    // fresh enable

        let toneOpens = tone(dbfs: -30, seconds: 1)
        var ys = [Float](repeating: 0, count: toneOpens.count)
        for i in 0..<toneOpens.count { ys[i] = g.process(toneOpens[i]) }
        let idx100 = Int(0.1 * sr)
        let ratios = windowedPeakRatios(x: toneOpens[idx100...], y: ys[idx100...])
        XCTAssertTrue(ratios.allSatisfy { $0 >= 0.99 },
                     "disable-then-enable must behave like a fresh gate (-30 dBFS opens per the absolute floor)")
    }

    // MARK: - 8. VoiceChain integration

    /// voiceGate == .off + disabled chain == passthrough (regression guard). Mirrors
    /// `MouthNoiseTests.testChainMouthNoiseOffIsPassthrough`.
    func testChainVoiceGateOffIsPassthrough() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.voiceGateLevel = .off
        chain.configure(s)
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "off+off must not modify samples")
    }

    func testChainVoiceGateHighIsActiveAndAttenuatesQuiet() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.voiceGateLevel = .high
        chain.configure(s)
        XCTAssertTrue(chain.isActive, "voiceGateLevel alone must activate the chain")

        let quiet = tone(dbfs: -50, seconds: 1)
        var buf = quiet
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        let idx400 = Int(0.4 * sr)
        let ratios = windowedPeakRatios(x: quiet[idx400...], y: buf[idx400...])
        XCTAssertTrue(ratios.allSatisfy { $0 <= 0.01 },
                     "a quiet -50 dBFS buffer must be attenuated once the gate closes")
    }

    /// IDENTITY AT REST (limiter must not run in gate-only mode): a LOUD (0.95, near the -1 dBFS
    /// ceiling) clean 1 kHz sine must pass through unchanged once the gate is open in steady
    /// state. Mirrors `MouthNoiseTests.testMouthNoiseOnlyPreservesLoudCleanSignal` exactly — 0.95
    /// is deliberately ABOVE the shared voice-chain limiter ceiling (-1 dB ≈ 0.891), so this test
    /// can actually detect the limiter engaging; a quieter probe (e.g. -6 dBFS ≈ 0.501) would stay
    /// under the ceiling regardless and couldn't catch a wrongly-engaged limiter.
    func testChainVoiceGateHighPreservesLoudCleanSignal() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.voiceGateLevel = .high
        chain.configure(s)

        let n = 9600
        var buf = [Float](repeating: 0, count: n)
        for i in 0..<n { buf[i] = 0.95 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        let ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        var maxDelta: Float = 0
        for i in (n / 2)..<n { maxDelta = max(maxDelta, abs(buf[i] - ref[i])) }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "gate-only mode must not limit a loud clean non-artifact signal")
    }

    // MARK: - Reset-group contract (mirrors MouthNoiseTests' clarity/mouthNoise reset-group tests)

    /// Shared conditioning: bring the gate to a deeply-closed state under `.high` (loud passage
    /// then a long quiet tail), so any subsequent behavior difference is attributable to what
    /// happens AFTER this point, not to the conditioning itself.
    private func conditionedHighGateChain() -> VoiceChain {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.voiceGateLevel = .high
        chain.configure(s)
        var loud = tone(dbfs: -12, seconds: 1)
        loud.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        var quiet = tone(dbfs: -46, seconds: 1)
        quiet.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        return chain
    }

    /// A short 200 Hz probe (matches the conditioning tone's frequency, so clarity's presence
    /// bell / de-esser — both centered well above 200 Hz — cannot confound a gate-only comparison).
    private func probeOutput(_ chain: VoiceChain) -> [Float] {
        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 200 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        return probe
    }

    /// Changing `voiceGateLevel` (.high → .low) while the chain stays active must reset the gate.
    /// We compare a chain that RECONFIGURES to `.low` against an otherwise-identically-conditioned
    /// chain that never reconfigures again (the "no-reconfigure run", still deeply closed under
    /// `.high`). If the reset happened, `gainDb` restarts at 0 (unity) and the probe passes through
    /// almost unchanged; if it didn't, `gainDb` stays near `.high`'s -60 dB floor and the probe
    /// stays heavily attenuated — a large, unambiguous difference either way.
    func testVoiceGateLevelChangeResetsGate() {
        let reconfigured = conditionedHighGateChain()
        var sLow = VoiceChainSettings.disabled
        sLow.voiceGateLevel = .low
        reconfigured.configure(sLow)
        let reconfiguredProbe = probeOutput(reconfigured)

        let notReconfigured = conditionedHighGateChain()
        let notReconfiguredProbe = probeOutput(notReconfigured)

        var maxDelta: Float = 0
        for i in 0..<reconfiguredProbe.count {
            maxDelta = max(maxDelta, abs(reconfiguredProbe[i] - notReconfiguredProbe[i]))
        }
        XCTAssertGreaterThan(maxDelta, 0.05,
                             "changing voiceGateLevel while active must reset the gate " +
                             "(probe output must differ from the no-reconfigure run)")
    }

    /// REGRESSION (bumpless carry-state contract): reconfiguring on an UNRELATED setting change
    /// (here, `clarity`) while `voiceGateLevel` stays the SAME must NOT reset the gate. We compare
    /// a chain that reconfigures with ONLY clarity changed against the no-reconfigure baseline —
    /// since the gate must carry its state either way, the probes must be identical (the 200 Hz
    /// probe frequency keeps clarity's own audible effect out of the comparison, see `probeOutput`).
    func testUnrelatedClarityChangeDoesNotResetVoiceGate() {
        let reconfigured = conditionedHighGateChain()
        var s = VoiceChainSettings.disabled
        s.voiceGateLevel = .high   // unchanged
        s.clarity = .low           // unrelated change
        reconfigured.configure(s)
        let reconfiguredProbe = probeOutput(reconfigured)

        let notReconfigured = conditionedHighGateChain()
        let notReconfiguredProbe = probeOutput(notReconfigured)

        var maxDelta: Float = 0
        for i in 0..<reconfiguredProbe.count {
            maxDelta = max(maxDelta, abs(reconfiguredProbe[i] - notReconfiguredProbe[i]))
        }
        XCTAssertLessThan(maxDelta, 1e-3,
                          "an unrelated clarity change must NOT reset the gate while voiceGateLevel " +
                          "stays the same (state must carry)")
    }
}
