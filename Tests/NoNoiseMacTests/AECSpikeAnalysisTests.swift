import XCTest
@testable import Core

/// Deterministic pseudo-random generator for test fixtures ONLY — deliberately independent of
/// `Date`/`arc4random` so a failing correlation test is reproducible, not flaky. Not the production
/// `SplitMix64` on purpose: these tests should not silently start passing/failing just because the
/// production generator's internals change.
private struct TestLCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    /// Next value in `[-1, 1)`.
    mutating func nextSample() -> Float {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        let top33 = state >> 31
        return Float(top33 % 2_000_000) / 1_000_000.0 - 1.0
    }
}

final class AECSpikeAnalysisTests: XCTestCase {

    // MARK: - windowedRMS

    func testWindowedRMSOfConstantSignalMatchesItsMagnitude() {
        let signal = [Float](repeating: 2.0, count: 12)
        let rms = AECSpikeAnalysis.windowedRMS(signal, windowFrames: 4)
        XCTAssertEqual(rms.count, 3)
        for value in rms {
            XCTAssertEqual(value, 2.0, accuracy: 0.0001)
        }
    }

    func testWindowedRMSDropsTrailingPartialWindow() {
        // 10 samples with windowFrames=4 → 2 full windows (8 samples); the trailing 2 are dropped.
        let signal = [Float](repeating: 1.0, count: 10)
        let rms = AECSpikeAnalysis.windowedRMS(signal, windowFrames: 4)
        XCTAssertEqual(rms.count, 2)
    }

    func testWindowedRMSOfEmptySignalIsEmpty() {
        XCTAssertEqual(AECSpikeAnalysis.windowedRMS([], windowFrames: 4), [])
    }

    // MARK: - normalizedCrossCorrelationPeak

    func testCorrelationPeakFindsKnownLagOnAttenuatedCopy() {
        var rng = TestLCG(seed: 1)
        let reference = (0..<2000).map { _ in rng.nextSample() }
        let knownLag = 1000
        var recorded = [Float](repeating: 0, count: reference.count + knownLag)
        for i in 0..<reference.count {
            recorded[i + knownLag] = reference[i] * 0.5
        }

        let result = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: reference, recorded: recorded, maxLagFrames: 1500)
        XCTAssertEqual(result.lagFrames, knownLag)
        XCTAssertGreaterThan(result.peak, 0.9)
    }

    func testCorrelationPeakIsLowForUncorrelatedNoise() {
        var rngA = TestLCG(seed: 11)
        var rngB = TestLCG(seed: 97)
        let reference = (0..<2000).map { _ in rngA.nextSample() }
        let recorded = (0..<2000).map { _ in rngB.nextSample() }

        let result = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: reference, recorded: recorded, maxLagFrames: 100)
        XCTAssertLessThan(result.peak, 0.2)
    }

    func testCorrelationPeakOfEmptyInputsIsZero() {
        let result = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: [], recorded: [1, 2, 3], maxLagFrames: 10)
        XCTAssertEqual(result.peak, 0)
        XCTAssertEqual(result.lagFrames, 0)
    }

    /// An inverted-phase (negated) echo is just as real as a same-phase one — a sign flip anywhere
    /// in an acoustic/software path is common. A plain `normalized > bestPeak` comparison (starting
    /// `bestPeak` at 0) would never register a strongly NEGATIVE correlation, silently reporting
    /// "no correlation" for a real, phase-inverted echo. `abs()` on the normalized score fixes this.
    func testCorrelationPeakFindsKnownLagOnInvertedAttenuatedCopy() {
        var rng = TestLCG(seed: 3)
        let reference = (0..<2000).map { _ in rng.nextSample() }
        let knownLag = 300
        var recorded = [Float](repeating: 0, count: reference.count + knownLag)
        for i in 0..<reference.count {
            recorded[i + knownLag] = reference[i] * -0.5
        }

        let result = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: reference, recorded: recorded, maxLagFrames: 500)
        XCTAssertEqual(result.lagFrames, knownLag)
        XCTAssertGreaterThan(result.peak, 0.4)
    }

    /// Regression for a real false positive (peak 0.641 on genuinely uncorrelated audio): once
    /// `recorded` is much shorter than `reference`, large lags overlap on only a handful of
    /// samples — and a 1-sample "vector" is mathematically ALWAYS ±1.0 normalized-correlated with
    /// anything nonzero, regardless of any real relationship. `minOverlapFraction` must exclude
    /// those lags so only lags with a statistically meaningful overlap are ever considered.
    func testOverlapGuardExcludesDegenerateShortOverlapLags() {
        var rngRef = TestLCG(seed: 5)
        let reference = (0..<1000).map { _ in rngRef.nextSample() }
        var rngRec = TestLCG(seed: 999)
        let recorded = (0..<20).map { _ in rngRec.nextSample() }

        let result = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: reference, recorded: recorded, maxLagFrames: 19)

        // Structural invariant: whatever lag won, its overlap must satisfy the >=50% floor — this
        // holds regardless of the RNG's actual output, so it can't be a flaky assertion.
        let minInputCount = Double(min(reference.count, recorded.count))
        let overlapAtChosenLag = Double(min(reference.count, recorded.count - result.lagFrames))
        XCTAssertGreaterThanOrEqual(overlapAtChosenLag, AECSpikeAnalysis.minOverlapFraction * minInputCount - 0.0001)

        // Numeric sanity net matching the originally-observed bug: without the guard, lag=19
        // (a single-sample overlap) would trivially score peak=1.0.
        XCTAssertLessThan(result.peak, 0.99)
    }

    // MARK: - burstOnOffRMS

    private func makeBurstPattern(totalFrames: Int, lagFrames: Int, periodFrames: Int, onFrames: Int,
                                  corruptedRange: Range<Int>? = nil) -> [Float] {
        var recorded = [Float](repeating: 0, count: totalFrames)
        for i in 0..<totalFrames {
            let shifted = i - lagFrames
            guard shifted >= 0 else { continue }
            let phase = shifted % periodFrames
            recorded[i] = phase < onFrames ? 1.0 : 0.0
        }
        if let corruptedRange {
            for i in corruptedRange where i >= 0 && i < totalFrames {
                recorded[i] = 0
            }
        }
        return recorded
    }

    func testBurstOnOffRMSSeparatesOnAndOffRegions() {
        let recorded = makeBurstPattern(totalFrames: 1000, lagFrames: 30, periodFrames: 200, onFrames: 100)
        let result = AECSpikeAnalysis.burstOnOffRMS(recorded: recorded, lagFrames: 30, periodFrames: 200, onFrames: 100, skipFrames: 0)
        XCTAssertEqual(result.onRMS, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.offRMS, 0.0, accuracy: 0.0001)
    }

    func testBurstOnOffRMSSkipFramesExcludesCorruptedStartupRegion() {
        // Corrupt (zero out) the first 250 frames' worth of what should be ON-phase samples,
        // simulating a startup/convergence transient.
        let recorded = makeBurstPattern(totalFrames: 1000, lagFrames: 30, periodFrames: 200, onFrames: 100,
                                        corruptedRange: 0..<250)

        // Without skipping, the corruption pulls the ON-window RMS below 1.0.
        let withoutSkip = AECSpikeAnalysis.burstOnOffRMS(recorded: recorded, lagFrames: 30, periodFrames: 200, onFrames: 100, skipFrames: 0)
        XCTAssertLessThan(withoutSkip.onRMS, 0.99)

        // Skipping past the corrupted region recovers the clean 1.0 / 0.0 pattern.
        let withSkip = AECSpikeAnalysis.burstOnOffRMS(recorded: recorded, lagFrames: 30, periodFrames: 200, onFrames: 100, skipFrames: 250)
        XCTAssertEqual(withSkip.onRMS, 1.0, accuracy: 0.0001)
        XCTAssertEqual(withSkip.offRMS, 0.0, accuracy: 0.0001)
    }

    func testBurstOnOffRMSOfEmptyRecordedIsZero() {
        let result = AECSpikeAnalysis.burstOnOffRMS(recorded: [], lagFrames: 0, periodFrames: 200, onFrames: 100, skipFrames: 0)
        XCTAssertEqual(result.onRMS, 0)
        XCTAssertEqual(result.offRMS, 0)
    }

    /// `lagFrames` larger than the whole recording shifts every sample's schedule index negative,
    /// so every sample is skipped (`shifted >= 0` guard) rather than indexed out of bounds — must
    /// not crash, and must report "nothing measured" as (0, 0) rather than a stale/garbage value.
    func testBurstOnOffRMSWithLagGreaterThanRecordedLengthDoesNotCrash() {
        let recorded = [Float](repeating: 1.0, count: 10)
        let result = AECSpikeAnalysis.burstOnOffRMS(recorded: recorded, lagFrames: 1000, periodFrames: 200, onFrames: 100, skipFrames: 0)
        XCTAssertEqual(result.onRMS, 0)
        XCTAssertEqual(result.offRMS, 0)
    }

    // MARK: - erleDb

    func testErleDbClampsToCeilingWhenResidualIsZero() {
        XCTAssertEqual(AECSpikeAnalysis.erleDb(residualRMS: 0, baselineEchoRMS: 1.0),
                      AECSpikeAnalysis.erleDbPerfectCancellationCeiling)
    }

    func testErleDbIsZeroWhenBaselineIsZero() {
        XCTAssertEqual(AECSpikeAnalysis.erleDb(residualRMS: 1.0, baselineEchoRMS: 0), 0)
    }

    func testErleDbComputesExpectedRatio() {
        // 0.1 vs 1.0 → 20*log10(10) = 20 dB.
        XCTAssertEqual(AECSpikeAnalysis.erleDb(residualRMS: 0.1, baselineEchoRMS: 1.0), 20, accuracy: 0.01)
    }

    // MARK: - dbfs

    func testDbfsClampsToFloorAtZero() {
        XCTAssertEqual(AECSpikeAnalysis.dbfs(0), AECSpikeAnalysis.dbfsSilenceFloor)
    }

    func testDbfsClampsToFloorForNegativeInput() {
        XCTAssertEqual(AECSpikeAnalysis.dbfs(-1), AECSpikeAnalysis.dbfsSilenceFloor)
    }

    func testDbfsOfFullScaleIsZero() {
        XCTAssertEqual(AECSpikeAnalysis.dbfs(1.0), 0, accuracy: 0.0001)
    }

    // MARK: - selfEchoVerdict

    func testSelfEchoVerdictPassesAtBothGates() {
        XCTAssertEqual(AECSpikeAnalysis.selfEchoVerdict(erleDb: 20, residualDbfs: -45), .pass)
    }

    func testSelfEchoVerdictMarginalWhenERLEJustBelowPassGate() {
        XCTAssertEqual(AECSpikeAnalysis.selfEchoVerdict(erleDb: 19.9, residualDbfs: -45), .marginal)
    }

    func testSelfEchoVerdictMarginalWhenResidualTooLoudDespiteHighERLE() {
        XCTAssertEqual(AECSpikeAnalysis.selfEchoVerdict(erleDb: 20, residualDbfs: -44), .marginal)
    }

    func testSelfEchoVerdictFailsBelowMarginalGate() {
        XCTAssertEqual(AECSpikeAnalysis.selfEchoVerdict(erleDb: 9.9, residualDbfs: -10), .fail)
    }

    func testSelfEchoVerdictMarginalAtExactMarginalGate() {
        XCTAssertEqual(AECSpikeAnalysis.selfEchoVerdict(erleDb: 10, residualDbfs: -10), .marginal)
    }

    // MARK: - crossProcessEchoDetected

    func testCrossProcessEchoDetectedAtThreshold() {
        XCTAssertTrue(AECSpikeAnalysis.crossProcessEchoDetected(correlationPeak: 0.2))
    }

    func testCrossProcessEchoNotDetectedBelowThreshold() {
        XCTAssertFalse(AECSpikeAnalysis.crossProcessEchoDetected(correlationPeak: 0.1999))
    }
}
