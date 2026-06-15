import Foundation

/// Feed-forward log-domain compressor. Per-sample, allocation-free.
public struct Compressor {
    private var thresholdDb: Float = 0
    private var ratio: Float = 1
    private var makeupDb: Float = 0
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var envDb: Float = 0          // smoothed gain-reduction (dB, >= 0)

    public init() {}

    public mutating func configure(thresholdDb: Float, ratio: Float, attackMs: Float,
                                   releaseMs: Float, makeupDb: Float, sampleRate: Float) {
        self.thresholdDb = thresholdDb
        self.ratio = max(ratio, 1)
        self.makeupDb = makeupDb
        attackCoeff = expf(-1.0 / (max(attackMs, 0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { envDb = 0 }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let mag = abs(x)
        let xDb = 20 * log10f(max(mag, 1e-9))
        let overDb = xDb - thresholdDb
        let targetGrDb = overDb > 0 ? overDb * (1 - 1 / ratio) : 0   // desired gain reduction (dB)
        // One-pole smoothing: attack when increasing reduction, release when decreasing.
        let coeff = targetGrDb > envDb ? attackCoeff : releaseCoeff
        envDb = coeff * envDb + (1 - coeff) * targetGrDb
        let gain = powf(10, (makeupDb - envDb) / 20)
        return x * gain
    }
}

/// Fast peak limiter with a final hard clamp that guarantees the ceiling.
public struct Limiter {
    private var ceilingLin: Float = 1
    private var releaseCoeff: Float = 0
    private var gain: Float = 1

    public init() {}

    public mutating func configure(ceilingDb: Float, releaseMs: Float, sampleRate: Float) {
        ceilingLin = powf(10, ceilingDb / 20)
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { gain = 1 }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let mag = abs(x)
        let desired: Float = mag > ceilingLin ? ceilingLin / mag : 1
        if desired < gain { gain = desired }                       // instant attack
        else { gain = releaseCoeff * gain + (1 - releaseCoeff) * 1 } // release toward unity
        let y = x * gain
        return max(-ceilingLin, min(ceilingLin, y))                 // safety clamp == hard ceiling
    }
}

/// Subtractive split-band de-esser. Isolates the sibilant band with a high-pass,
/// follows its envelope, and removes a fraction of that band when it exceeds
/// threshold: `out = x - frac·sib`. Below threshold (and when disabled) `frac = 0`,
/// so output == input **exactly** — it never colors the voice except on real
/// "ess"/"sh" transients, and it never touches the low/mid vocal body.
public struct DeEsser {
    private var sib = Biquad()           // high-pass isolating the sibilant band
    private var enabled = false
    private var thresholdLin: Float = 1  // detector threshold (linear)
    private var maxReduction: Float = 0  // max fraction of the sib band to remove (0…1)
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var env: Float = 0           // smoothed |sib| envelope (linear)

    public init() {}

    public mutating func configure(crossoverHz: Float, thresholdDb: Float, maxReductionDb: Float,
                                   attackMs: Float, releaseMs: Float, sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { sib.setBypass(); env = 0; return }
        sib.setHighPass(freq: crossoverHz, sampleRate: sampleRate, q: 0.707)
        thresholdLin = powf(10, thresholdDb / 20)
        // Convert "max dB to pull the band down" into a max removed-fraction, so
        // out = x - frac·sib reduces the band by at most maxReductionDb and never inverts it.
        maxReduction = min(1, 1 - powf(10, -abs(maxReductionDb) / 20))
        attackCoeff = expf(-1.0 / (max(attackMs, 0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { env = 0; sib.reset() }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let s = sib.process(x)                 // sibilant band (state advances every sample)
        let mag = abs(s)
        let coeff = mag > env ? attackCoeff : releaseCoeff
        env = coeff * env + (1 - coeff) * mag
        guard env > thresholdLin else { return x }   // below threshold → exact identity
        let over = env / thresholdLin                // > 1 here
        let frac = maxReduction * (1 - 1 / over)      // 0 at threshold → maxReduction when loud
        return x - frac * s                           // remove only the sibilant band
    }
}

/// Subtractive low-band de-plosive. Detects P-pop / B-thump transients by
/// tracking the ratio of low-band energy (< `splitHz`) to total energy, and
/// subtractively removes a fraction of the low band when both the total energy
/// and the low-band ratio exceed their respective thresholds:
///   `out = x - frac·lowSig`
/// Below threshold (and when disabled) `frac = 0`, so `out = x` exactly —
/// the mid-range voice body and consonant bursts pass through untouched.
public struct DePlosive {
    // Low-band split: the "low" signal is `x - hp(x)`.
    private var hp = Biquad()           // high-pass at `splitHz` to isolate lo band
    private var enabled = false
    private var thresholdLin: Float = 1 // total-energy threshold (linear amplitude)
    private var lowRatioGuard: Float = 0.60  // lo/(lo+hi) must exceed this to flag plosive
    private var maxReduction: Float = 0      // max fraction of lowSig to subtract (0…1)
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var totalEnv: Float = 0     // smoothed |x| total-energy envelope
    private var lowEnv: Float = 0       // smoothed |lowSig| envelope

    public init() {}

    public mutating func configure(splitHz: Float, thresholdDb: Float, lowRatioGuard: Float,
                                   maxReductionDb: Float, attackMs: Float, releaseMs: Float,
                                   sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { hp.setBypass(); totalEnv = 0; lowEnv = 0; return }
        hp.setHighPass(freq: splitHz, sampleRate: sampleRate, q: 0.707)
        thresholdLin = powf(10, thresholdDb / 20)
        self.lowRatioGuard = max(0, min(1, lowRatioGuard))
        maxReduction = min(1, 1 - powf(10, -abs(maxReductionDb) / 20))
        attackCoeff  = expf(-1.0 / (max(attackMs,  0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { totalEnv = 0; lowEnv = 0; hp.reset() }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        // EXACTLY ONE filter advance per input sample. `Biquad.process` mutates z1/z2
        // on every call, so a second "peek" (e.g. `hp.process(0)`) would corrupt the
        // high-pass state and desync detection from the render output. Detection below
        // reads ONLY the scalar envelopes — never a second filter call.
        let hiSig = hp.process(x)
        let lowSig = x - hiSig          // low-band component (below splitHz)

        // Update envelope followers.
        let totalMag = abs(x)
        let lowMag   = abs(lowSig)
        let tCoeff = totalMag > totalEnv ? attackCoeff : releaseCoeff
        let lCoeff = lowMag   > lowEnv   ? attackCoeff : releaseCoeff
        totalEnv = tCoeff * totalEnv + (1 - tCoeff) * totalMag
        lowEnv   = lCoeff * lowEnv   + (1 - lCoeff) * lowMag

        // Detect plosive: total energy must exceed threshold AND the low band must
        // dominate (lowEnv / totalEnv >= lowRatioGuard) to avoid suppressing consonant bursts.
        guard totalEnv > thresholdLin else { return x }
        let ratio = lowEnv / max(totalEnv, 1e-12)   // scalar-only ratio; no extra filter advance
        guard ratio >= lowRatioGuard else { return x }

        // Subtractive low-band reduction (same shape as DeEsser.process).
        let over = totalEnv / thresholdLin   // > 1
        let frac = maxReduction * (1 - 1 / over)
        return x - frac * lowSig
    }
}

/// Broadband transient gate for mouth clicks and lip-smacks. Tracks a fast
/// instantaneous envelope and a slow background RMS. A click is a *few-sample*
/// spike where the fast envelope rises far above the slow background; a phoneme
/// onset is a spike that *sustains*. The gate therefore engages only when the
/// fast/slow ratio is tripped for a SHORT run (≤ `maxClickSamples`); once the
/// trip-run exceeds that, the transient is treated as voiced content, the gain
/// snaps back to unity, and the gate latches off until the ratio falls back —
/// so ordinary voiced onsets and the voiced body pass through unchanged.
///
/// **Identity at rest is non-negotiable: the gate NEVER fires from cold silence,
/// and re-disarms on any realistic pause.** A click is only meaningful *relative to
/// an established speech background*. The gate is armed only after the slow background
/// has stayed above `minThresholdLin` continuously for `warmupSamples` (one slow-release
/// time-constant). Disarm is driven by an INDEPENDENT instantaneous-silence detector,
/// NOT by `slowEnv`: because `slowEnv` releases over ~200 ms, a realistic 200–300 ms
/// pause leaves it still above `minThresholdLin` (so it must NOT gate disarm). Instead a
/// `silenceCounter` counts consecutive samples whose instantaneous level (`|x|`) is below
/// the silence floor (`minThresholdLin`); after `silenceSamples` (≈75 ms) the gate
/// force-disarms (`warmupCounter = 0`). Any above-floor sample resets `silenceCounter`,
/// so voiced zero-crossings never disarm mid-speech. While unarmed (cold start, or just
/// after a disarm) `process` returns `x` BIT-EXACTLY (`gain` held at 1.0; no envelope
/// ratio is even consulted for gating). This makes a voiced onset after silence an exact
/// identity from sample 0 — both at cold start AND after every realistic pause — instead
/// of letting a near-zero `slowEnv` fabricate a huge fast/slow ratio that clips the first
/// ~1 ms of clean speech.
///
/// **Documented tradeoff:** a click occurring from *total* silence (no preceding
/// speech to establish a background) is intentionally MISSED. Per the requirement,
/// missing a from-silence click is strictly preferable to dulling a clean voiced
/// onset — the overwhelmingly common case. Clicks during or after speech (the
/// realistic mouth-noise case) still have an established background and are caught.
///
/// Below the ratio (and when disabled) `gain = 1.0` exactly.
///
/// **State-carry contract (mirrors `DeEsser`):** `configure(enabled: true)` updates
/// parameters/coefficients ONLY — it MUST NOT clear the runtime detector state
/// (`fastEnv`, `slowEnv`, `gain`, `holdCounter`, `tripRun`, `latched`, `warmupCounter`,
/// `silenceCounter`). Runtime state is cleared ONLY by `reset()` and by the disabled arm. `VoiceChain`
/// decides when to reset (full reset on inactive→active; mouth-noise-stages reset when
/// `MouthNoiseLevel` itself changes), so reconfiguring on an UNRELATED setting change
/// (clarity, voice polish) is bumpless and never cold-restarts the gate.
public struct DeClick {
    private var enabled = false
    private var clickRatio: Float = 6.0       // fast/slow ratio to flag a click
    private var minThresholdLin: Float = 1e-6 // absolute floor: arms the warm-up + ratio test
    private var gainFloor: Float = 0.25       // minimum gain during a click event
    private var fastAttackCoeff: Float = 0
    private var fastReleaseCoeff: Float = 0
    private var slowAttackCoeff: Float = 0
    private var slowReleaseCoeff: Float = 0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0
    private var holdReleaseCoeff: Float = 0   // gain release after hold expires
    private var maxClickSamples: Int = 0      // longest trip-run still treated as a click
    private var warmupSamples: Int = 0        // background must be established this long before arming
    private var warmupCounter: Int = 0        // consecutive samples slowEnv has been above the floor
    private var silenceSamples: Int = 0       // consecutive instantaneous-silence samples that force a disarm (≈75 ms)
    private var silenceCounter: Int = 0       // consecutive samples |x| has stayed below the silence floor
    private var tripRun: Int = 0              // consecutive samples the ratio has been tripped
    private var latched = false               // true = trip-run exceeded; ignore until ratio falls
    private var fastEnv: Float = 0
    private var slowEnv: Float = 0            // starts at 0; gate stays disarmed until background established
    private var gain: Float = 1.0

    // Continuous instantaneous silence (ms) that forces a disarm. Fixed: a click is meaningful
    // only against an ESTABLISHED background, and a realistic pause is ≥ 200 ms — 75 ms re-arms
    // cold well inside that window while staying immune to per-cycle voiced zero-crossings.
    private static let silenceDisarmMs: Float = 75

    public init() {}

    /// Update parameters/coefficients. Mirrors `DeEsser.configure`: the `enabled`
    /// arm does NOT touch runtime state — only `reset()` and the disabled arm clear it.
    public mutating func configure(fastAttackMs: Float, fastReleaseMs: Float,
                                   slowAttackMs: Float, slowReleaseMs: Float,
                                   clickRatio: Float, minThresholdDb: Float,
                                   holdReleaseMs: Float, gainFloor: Float,
                                   sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { reset(); return }
        self.clickRatio = max(1, clickRatio)
        self.gainFloor = max(0, min(1, gainFloor))
        minThresholdLin = powf(10, minThresholdDb / 20)
        fastAttackCoeff  = expf(-1.0 / (max(fastAttackMs,  0.01) * 0.001 * sampleRate))
        fastReleaseCoeff = expf(-1.0 / (max(fastReleaseMs, 0.01) * 0.001 * sampleRate))
        slowAttackCoeff  = expf(-1.0 / (max(slowAttackMs,  0.01) * 0.001 * sampleRate))
        slowReleaseCoeff = expf(-1.0 / (max(slowReleaseMs, 0.01) * 0.001 * sampleRate))
        holdSamples = Int(max(holdReleaseMs, 0.01) * 0.001 * sampleRate)
        // A click is at most ~1 ms of anomalous rise; anything longer is voiced content.
        maxClickSamples = max(1, Int(0.001 * sampleRate))
        // Require one slow-release time-constant of established background before arming
        // the gate. From cold silence the gate stays disarmed → voiced onset is exact identity.
        warmupSamples = max(1, Int(max(slowReleaseMs, 0.01) * 0.001 * sampleRate))
        // Disarm on ACTUAL silence (instantaneous level below the floor), NOT on slowEnv
        // decay: slowEnv's ~200 ms release leaves it above the floor through a normal pause,
        // so it would keep the gate armed and let the next clean onset be attenuated. 75 ms of
        // continuous instantaneous silence is short enough to re-arm cold after a realistic
        // 200–300 ms pause, yet long enough that voiced zero-crossings never trip it mid-speech.
        silenceSamples = max(1, Int(DeClick.silenceDisarmMs * 0.001 * sampleRate))
        // Release from gainFloor → 1.0 over the same holdReleaseMs window.
        holdReleaseCoeff = expf(-1.0 / (max(holdReleaseMs, 0.01) * 0.001 * sampleRate))
        // NOTE: runtime detector state is intentionally NOT cleared here (bumpless on
        // unrelated reconfigures). Clearing happens only in reset() / the disabled arm.
    }

    public mutating func reset() {
        fastEnv = 0; slowEnv = 0; gain = 1
        holdCounter = 0; tripRun = 0; warmupCounter = 0; silenceCounter = 0; latched = false
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let mag = abs(x)

        // Fast envelope: tracks instantaneous amplitude.
        let fCoeff = mag > fastEnv ? fastAttackCoeff : fastReleaseCoeff
        fastEnv = fCoeff * fastEnv + (1 - fCoeff) * mag

        // Slow envelope: tracks the speech background.
        let sCoeff = mag > slowEnv ? slowAttackCoeff : slowReleaseCoeff
        slowEnv = sCoeff * slowEnv + (1 - sCoeff) * mag

        // Instantaneous-silence disarm: count consecutive samples whose INSTANTANEOUS level
        // is below the floor. `mag` (not `slowEnv`) is the disarm signal — slowEnv's ~200 ms
        // release stays above the floor through a normal pause, so it would keep the gate
        // armed and let the next clean onset be attenuated. Any above-floor sample resets the
        // counter, so voiced zero-crossings never accumulate enough to disarm mid-speech.
        if mag <= minThresholdLin {
            if silenceCounter < silenceSamples { silenceCounter += 1 }
        } else {
            silenceCounter = 0
        }
        // After `silenceSamples` of continuous silence (≈75 ms), force a cold disarm so the
        // NEXT voiced onset re-arms from scratch and is exact identity from sample 0.
        if silenceCounter >= silenceSamples { warmupCounter = 0 }

        // Warm-up: a click is only meaningful relative to an ESTABLISHED background. Count
        // continuous samples the slow background has been above the floor; the gate is armed
        // only once it has been established for `warmupSamples`. Disarm is handled above by
        // the instantaneous-silence detector, NOT by slowEnv.
        if slowEnv > minThresholdLin {
            if warmupCounter < warmupSamples { warmupCounter += 1 }
        }
        let armed = warmupCounter >= warmupSamples

        // IDENTITY AT REST: until a background is established (e.g. a voiced onset after
        // silence), the gate cannot fire. Force gain to exactly 1.0 and return x bit-for-bit.
        guard armed else {
            gain = 1
            holdCounter = 0; tripRun = 0; latched = false
            return x
        }

        // Ratio test against the established background.
        let ratioTripped = fastEnv > clickRatio * slowEnv && fastEnv > minThresholdLin

        // Distinguish a few-sample click from a sustained voiced onset by trip-run length.
        if ratioTripped {
            tripRun += 1
            if tripRun > maxClickSamples {
                // Sustained rise → voiced content, not a click. Snap to unity and latch
                // off until the ratio falls back below threshold (prevents dulling onsets).
                latched = true
            }
        } else {
            tripRun = 0
            latched = false   // transient ended → ready to detect the next genuine click
        }

        let isClick = ratioTripped && !latched

        if isClick {
            gain = gainFloor          // instantaneous attack to floor
            holdCounter = holdSamples // arm the hold
        } else if latched {
            gain = 1                  // sustained content: force unity, no coloration
            holdCounter = 0
        } else if holdCounter > 0 {
            holdCounter -= 1
            // During hold: gain stays at floor (or wherever attack left it).
        } else {
            // Release back to unity.
            gain = holdReleaseCoeff * gain + (1 - holdReleaseCoeff) * 1.0
        }

        return x * gain
    }
}
