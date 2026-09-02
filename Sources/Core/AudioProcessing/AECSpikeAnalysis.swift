import Foundation
import Accelerate

/// Pure analysis helpers for the AEC (Acoustic Echo Cancellation) feasibility spike behind
/// `--aec-spike`. No CoreAudio/AVFoundation dependencies — every function here operates on plain
/// `[Float]` buffers and is host-unit-testable independent of audio hardware, mirroring the
/// project's "risky/quantitative math lives in tested statics" rule (see AGENTS.md — `Biquad`,
/// `LoudnessMeter`, `SpeakerTapLogic`, etc. follow the same shape).
///
/// `VoiceIOSpikeRunner` (the actual harness that drives AVAudioEngine + records/plays audio) is the
/// only caller; keeping the math here, decoupled from AVFoundation, is what makes it testable.
public enum AECSpikeAnalysis {

    // MARK: - Named thresholds (no magic numbers at call sites)

    /// `erleDb` clamp when the residual is at/below zero (perfect cancellation) — avoids `log10(0)`.
    public static let erleDbPerfectCancellationCeiling: Float = 80

    /// `dbfs` clamp for a zero/negative RMS (silence) — avoids `log10(0)` = -infinity.
    public static let dbfsSilenceFloor: Float = -120

    /// `selfEchoVerdict`: ERLE at/above this dB (AND a low-enough residual) is a clean pass.
    public static let selfEchoPassERLEDb: Float = 20
    /// `selfEchoVerdict`: residual level at/below this dBFS is inaudible (part of the pass gate).
    public static let selfEchoPassResidualDbfs: Float = -45
    /// `selfEchoVerdict`: ERLE at/above this (but below the pass gate) is a marginal result.
    public static let selfEchoMarginalERLEDb: Float = 10

    /// `crossProcessEchoDetected`: a normalized correlation peak at/above this is treated as "echo
    /// is still present" — i.e. Voice Processing I/O did not cancel audio played by ANOTHER process.
    public static let crossEchoDetectionPeakThreshold: Float = 0.2

    // MARK: - Windowed RMS

    /// RMS of each non-overlapping `windowFrames`-length window of `x`. Trailing samples that don't
    /// fill a whole window are dropped (never a short, misleadingly-noisy final window).
    public static func windowedRMS(_ x: [Float], windowFrames: Int) -> [Float] {
        guard windowFrames > 0, !x.isEmpty else { return [] }
        let windowCount = x.count / windowFrames
        guard windowCount > 0 else { return [] }
        var result = [Float](repeating: 0, count: windowCount)
        x.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<windowCount {
                var rms: Float = 0
                vDSP_rmsqv(base + i * windowFrames, 1, &rms, vDSP_Length(windowFrames))
                result[i] = rms
            }
        }
        return result
    }

    // MARK: - Normalized cross-correlation

    /// Slides `recorded` against `reference` over lags `0...maxLagFrames` and returns the maximum
    /// normalized cross-correlation (dot product normalized by both signals' norms over the
    /// overlapping window) plus the lag at which it occurs. A peak near 1.0 means `recorded`
    /// contains an (attenuated/delayed) copy of `reference`; a peak near 0 means it doesn't.
    ///
    /// Minimum fraction (of `min(reference.count, recorded.count)`) that a lag's overlap window
    /// must reach to be considered at all. Without this floor, a lag near the end of a short
    /// `recorded` buffer can overlap on just one or two samples — and a 1-sample "vector" is
    /// mathematically ALWAYS ±1.0 normalized-correlated with anything nonzero, a trivial false
    /// positive that has nothing to do with actual echo/correlation. Measured in practice: a
    /// short, genuinely uncorrelated recording produced a spurious peak of 0.641 before this guard.
    public static let minOverlapFraction: Double = 0.5

    /// O(N * maxLagFrames) — a deliberately simple implementation. This runs once per spike scenario
    /// (a few seconds of audio), not in any real-time path, so the naive cost is acceptable.
    ///
    /// Returns the ABSOLUTE value of the best normalized correlation (and the lag it occurs at).
    /// An inverted-phase echo (common after any gain-sign flip in an acoustic/software path) would
    /// otherwise score a strongly NEGATIVE correlation at the true lag, which a plain `>` comparison
    /// against a `bestPeak` starting at 0 would never surface — silently reporting "no correlation
    /// found" for a real, just phase-inverted, echo.
    public static func normalizedCrossCorrelationPeak(reference: [Float], recorded: [Float],
                                                       maxLagFrames: Int) -> (peak: Float, lagFrames: Int) {
        guard !reference.isEmpty, !recorded.isEmpty, maxLagFrames >= 0 else { return (0, 0) }
        let minInputCount = Double(min(reference.count, recorded.count))
        var bestPeak: Float = 0
        var bestLag = 0
        reference.withUnsafeBufferPointer { refBuf in
            recorded.withUnsafeBufferPointer { recBuf in
                guard let refBase = refBuf.baseAddress, let recBase = recBuf.baseAddress else { return }
                let lastLag = min(maxLagFrames, recorded.count - 1)
                guard lastLag >= 0 else { return }
                for lag in 0...lastLag {
                    let overlap = min(reference.count, recorded.count - lag)
                    guard overlap > 0, Double(overlap) >= minOverlapFraction * minInputCount else { continue }
                    let recAtLag = recBase + lag
                    var dot: Float = 0
                    vDSP_dotpr(refBase, 1, recAtLag, 1, &dot, vDSP_Length(overlap))
                    var refNormSq: Float = 0
                    vDSP_dotpr(refBase, 1, refBase, 1, &refNormSq, vDSP_Length(overlap))
                    var recNormSq: Float = 0
                    vDSP_dotpr(recAtLag, 1, recAtLag, 1, &recNormSq, vDSP_Length(overlap))
                    let denom = (refNormSq * recNormSq).squareRoot()
                    let normalized: Float = denom > 0 ? abs(dot / denom) : 0
                    if normalized > bestPeak {
                        bestPeak = normalized
                        bestLag = lag
                    }
                }
            }
        }
        return (bestPeak, bestLag)
    }

    // MARK: - Burst ON/OFF RMS

    /// Applies a known playback schedule (period `periodFrames`, first `onFrames` of each period
    /// ON) shifted by `lagFrames` onto `recorded`, skips the first `skipFrames` samples (DFN/VPIO
    /// convergence or startup transient), and returns the combined RMS of the ON-labeled samples
    /// vs. the OFF-labeled samples.
    public static func burstOnOffRMS(recorded: [Float], lagFrames: Int, periodFrames: Int,
                                     onFrames: Int, skipFrames: Int) -> (onRMS: Float, offRMS: Float) {
        guard periodFrames > 0, onFrames >= 0, onFrames <= periodFrames, !recorded.isEmpty else {
            return (0, 0)
        }
        let start = max(0, skipFrames)
        guard start < recorded.count else { return (0, 0) }
        var onSumSq: Double = 0
        var onCount = 0
        var offSumSq: Double = 0
        var offCount = 0
        recorded.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in start..<recorded.count {
                let shifted = i - lagFrames
                guard shifted >= 0 else { continue }
                let phase = shifted % periodFrames
                let sample = Double(base[i])
                if phase < onFrames {
                    onSumSq += sample * sample
                    onCount += 1
                } else {
                    offSumSq += sample * sample
                    offCount += 1
                }
            }
        }
        let onRMS = onCount > 0 ? Float((onSumSq / Double(onCount)).squareRoot()) : 0
        let offRMS = offCount > 0 ? Float((offSumSq / Double(offCount)).squareRoot()) : 0
        return (onRMS, offRMS)
    }

    // MARK: - Level helpers

    /// Echo Return Loss Enhancement: how many dB quieter the residual echo is vs. the (uncancelled)
    /// baseline echo. `baselineEchoRMS <= 0` means there was no measurable baseline echo, so ERLE is
    /// undefined → 0. `residualRMS <= 0` means the echo was reduced below measurement floor →
    /// clamp to `erleDbPerfectCancellationCeiling` rather than `+infinity`.
    public static func erleDb(residualRMS: Float, baselineEchoRMS: Float) -> Float {
        guard baselineEchoRMS > 0 else { return 0 }
        guard residualRMS > 0 else { return erleDbPerfectCancellationCeiling }
        return 20 * log10(baselineEchoRMS / residualRMS)
    }

    /// Full-scale dB for a linear RMS value. `rms <= 0` clamps to `dbfsSilenceFloor` (avoids -inf).
    public static func dbfs(_ rms: Float) -> Float {
        guard rms > 0 else { return dbfsSilenceFloor }
        return 20 * log10(rms)
    }

    // MARK: - Verdicts

    public enum SpikeVerdict: String {
        case pass
        case marginal
        case fail
    }

    /// Verdict for the self-echo (loopback) scenario: a clean pass needs BOTH enough ERLE and a
    /// low absolute residual (high ERLE with a loud residual just means the baseline was very loud).
    public static func selfEchoVerdict(erleDb: Float, residualDbfs: Float) -> SpikeVerdict {
        if erleDb >= selfEchoPassERLEDb, residualDbfs <= selfEchoPassResidualDbfs {
            return .pass
        }
        if erleDb >= selfEchoMarginalERLEDb {
            return .marginal
        }
        return .fail
    }

    /// Whether the cross-process scenario still shows detectable echo (VPIO's built-in AEC only
    /// cancels audio played by the SAME process's output node — this checks whether that limitation
    /// actually shows up against audio played by an unrelated process like `afplay`).
    public static func crossProcessEchoDetected(correlationPeak: Float) -> Bool {
        correlationPeak >= crossEchoDetectionPeakThreshold
    }
}
