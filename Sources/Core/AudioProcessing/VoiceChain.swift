import Foundation

/// "Broadcast Voice" intensity. Drives a coupled presence lift + de-esser so the
/// voice sounds clearer/more present while keeping its original identity. `.off`
/// is a true no-op (presence bypassed, de-esser identity).
public enum ClarityLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// Presence (peaking-bell) lift in dB. Conservative by design — a gentle,
    /// wide lift adds clarity without coloring the voice. Tunable starting points.
    public var presenceDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 1.5
        case .medium: return 3
        case .high:   return 4.5
        }
    }

    /// Maximum de-ess reduction (dB) of the sibilant band. Scales WITH the
    /// presence lift so added "air" never turns into harsh sibilance.
    public var deEssMaxReductionDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 4
        case .medium: return 6
        case .high:   return 8
        }
    }
}

/// Fixed band/timing constants for the Broadcast Voice stages (tunable starting points).
enum ClarityProfile {
    static let presenceHz: Float = 4500
    static let presenceQ: Float = 0.7
    static let deEssCrossoverHz: Float = 6000
    static let deEssThresholdDb: Float = -28
    static let deEssAttackMs: Float = 1
    static let deEssReleaseMs: Float = 80
}

/// "Mouth Noise Finisher" intensity. Controls the de-plosive (P-pop/thump suppressor)
/// and de-click (lip-smack/mouth-click suppressor) stages. `.off` is a true no-op —
/// both stages return `x` unchanged, and all existing presets are unaffected.
public enum MouthNoiseLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// Maximum de-plosive low-band reduction in dB. Intentionally conservative —
    /// voiced stops (B, D, G) share low-band energy with plosives; excess reduction
    /// dulls them. Starting points, tunable after listening.
    public var maxPlosReductionDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 8
        case .medium: return 14
        case .high:   return 20
        }
    }

    /// De-click gain floor (linear). How far the gain drops during a click event.
    /// `.off` = 1.0 (identity); lower = more suppression.
    public var clickGainFloor: Float {
        switch self {
        case .off:    return 1.0
        case .low:    return 0.50   // −6 dB
        case .medium: return 0.35   // ~−9 dB
        case .high:   return 0.25   // −12 dB
        }
    }
}

/// Fixed band/timing constants for the mouth-noise finisher stages (tunable starting points).
/// All values chosen conservatively — they target artifacts that are distinctly sharper or
/// more low-heavy than any voiced phoneme.
enum MouthNoiseProfile {
    // De-plosive — transient low-band surge detector (validated against sustained vowels,
    // vowel onsets, hum and 40–60 Hz P-pops: 0% fire on voiced content).
    static let plosiveSplitHz: Float    = 120    // low/high split frequency
    static let plosiveSurgeRatio: Float = 2.5    // low-band fast/slow rise that flags a transient
    static let plosiveDominance: Float  = 0.78   // low/(low+high) concentration gate
    static let plosiveFloorDb: Float    = -50    // absolute low-band floor to arm detection
    static let plosiveAttackMs: Float   = 2.0    // reduction engage
    static let plosiveReleaseMs: Float  = 40.0   // reduction release

    // De-click — instant-attack peak follower vs slow background, wall-clock event latch.
    static let clickPeakReleaseMs: Float = 1.5
    static let clickSlowAttackMs: Float  = 10.0
    static let clickSlowReleaseMs: Float = 200.0
    static let clickRatio: Float         = 3.0   // peak/slow ratio to flag a click
    static let clickMinThresholdDb: Float = -54  // absolute floor (quiet rooms don't trigger)
    static let clickHoldMs: Float        = 1.5   // hold at floor after a click
    static let clickReleaseMs: Float     = 5.0   // smooth gain release back to unity
    static let clickMaxClickMs: Float    = 2.0   // events longer than this latch off as voiced
}

/// "Voice Gate" intensity — a downward expander that attenuates other people's voices picked up
/// by a headset mic while the wearer isn't speaking (see `VoiceGate`). The adaptive threshold
/// tracks the wearer's own learned speaking level, so `marginDb`/`absoluteFloorDb` set how far
/// below that level still counts as "the wearer," and `floorDb` sets how hard everything else
/// gets attenuated. `.off` is a true no-op.
public enum VoiceGateLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// dB below the learned speaker-peak level that still counts as the wearer speaking.
    /// Larger = more tolerant of quieter wearer speech before the gate closes.
    public var marginDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 12
        case .medium: return 8
        case .high:   return 6
        }
    }

    /// Absolute floor for the open threshold (dBFS) — a hard lower bound so a very quiet room
    /// doesn't let the adaptive margin open the gate for near-silence. This dBFS value is
    /// measured at the voice chain's own input — i.e. AFTER `DeepFilterNetDSP.outputGain` (and,
    /// on the live path, after the pre-DSP Input Volume trim) — so a non-unity gain shifts the
    /// effective mic-referred threshold by the same amount.
    public var absoluteFloorDb: Float {
        switch self {
        case .off:    return -100
        case .low:    return -48
        case .medium: return -42
        case .high:   return -36
        }
    }

    /// Gain applied while closed, in dB. More negative = more attenuation of other talkers.
    public var floorDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return -15
        case .medium: return -30
        case .high:   return -60
        }
    }

    /// Hysteresis (dB) between the open and close thresholds — avoids chatter at the boundary.
    public var hysteresisDb: Float {
        switch self {
        case .off:                 return 0
        case .low:          return 6
        case .medium, .high: return 4
        }
    }

    /// Hold time (ms) after dropping below the close threshold before the gate actually closes —
    /// bridges brief pauses inside the wearer's own speech.
    public var holdMs: Float {
        switch self {
        case .off:    return 0
        case .low:    return 250
        case .medium: return 200
        case .high:   return 150
        }
    }
}

/// Fixed detector time constants for the voice gate (tunable starting points, not user knobs).
/// These shape the envelope/peak-tracker response and are shared by every `VoiceGateLevel`.
enum VoiceGateProfile {
    static let envAttackMs: Float = 1
    static let envReleaseMs: Float = 40
    static let peakAttackMs: Float = 20
    static let peakReleaseMs: Float = 30_000
    static let attackMs: Float = 3
    static let releaseMs: Float = 60
}

public struct VoiceChainSettings: Sendable, Equatable {
    public var enabled: Bool
    public var highPassHz: Float
    public var lowShelfHz: Float
    public var lowShelfDb: Float
    public var highShelfHz: Float
    public var highShelfDb: Float
    public var compThresholdDb: Float
    public var compRatio: Float
    public var compAttackMs: Float
    public var compReleaseMs: Float
    public var compMakeupDb: Float
    public var limiterCeilingDb: Float
    public var clarity: ClarityLevel = .off
    public var mouthNoiseLevel: MouthNoiseLevel = .off
    public var voiceGateLevel: VoiceGateLevel = .off
    /// Loudness normalization is on. An independent activation reason: when true the
    /// chain runs (limiter + pre-limiter make-up gain) even with polish and clarity
    /// off, so normalization works in Meeting mode. Default false → no behavior change.
    public var loudnessActive: Bool = false

    public static let disabled = VoiceChainSettings(
        enabled: false, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 0,
        highShelfHz: 8000, highShelfDb: 0, compThresholdDb: 0, compRatio: 1,
        compAttackMs: 10, compReleaseMs: 120, compMakeupDb: 0, limiterCeilingDb: -1)
}

/// Time-domain voice-shaping chain: high-pass → low-shelf → high-shelf →
/// presence (peaking bell) → de-esser → de-plosive → de-click → gate → compressor → limiter.
/// Per-sample, allocation-free. `configure` runs on main; `process` runs on the render
/// thread and no-ops when inactive (`enabled`, `clarity`, `mouthNoiseLevel`, `loudnessActive`,
/// and `voiceGateLevel` all off/false).
public final class VoiceChain {
    private let sampleRate: Float
    private var hp = Biquad()
    private var lowShelf = Biquad()
    private var highShelf = Biquad()
    private var presence = Biquad()
    private var comp = Compressor()
    private var limiter = Limiter()
    private var deEsser = DeEsser()
    private var dePlosive = DePlosive()
    private var deClick = DeClick()
    private var gate = VoiceGate()
    private var mouthNoise: MouthNoiseLevel = .off
    private var voiceGate: VoiceGateLevel = .off
    private var enabled = false
    private var clarity: ClarityLevel = .off
    private var loudnessActive = false
    private var active = false
    /// Loudness-normalization make-up gain (linear). Written from main (lock-free
    /// scalar; atomic on arm64), read on the render thread. 1.0 = no-op. Applied
    /// just BEFORE the limiter so the ceiling still bounds the boosted signal.
    private var loudnessGain: Float = 1

    public init(sampleRate: Float = 48000) {
        self.sampleRate = sampleRate
        hp.setBypass(); lowShelf.setBypass(); highShelf.setBypass(); presence.setBypass()
    }

    public func configure(_ s: VoiceChainSettings) {
        let wasActive = active
        let priorClarity = clarity
        let priorMouthNoise = mouthNoise
        let priorGate = voiceGate
        enabled = s.enabled
        clarity = s.clarity
        mouthNoise = s.mouthNoiseLevel
        voiceGate = s.voiceGateLevel
        loudnessActive = s.loudnessActive
        active = s.enabled || s.clarity != .off || s.mouthNoiseLevel != .off ||
                 s.loudnessActive || s.voiceGateLevel != .off
        guard active else { return }
        // Clean start when the chain becomes active (don't inherit frozen state).
        // Switching between two *active* settings is intentionally bumpless EXCEPT for the
        // stage group whose level changed — its stale envelope/gain state would ring on
        // re-enable and color the voice, so reset ONLY that group. Independent `if` checks
        // (not `else if`) so a simultaneous clarity+mouthNoise+gate change resets ALL affected groups.
        if !wasActive {
            reset()
        } else {
            if clarity != priorClarity { presence.reset(); deEsser.reset() }
            if mouthNoise != priorMouthNoise { dePlosive.reset(); deClick.reset() }
            if voiceGate != priorGate { gate.reset() }
        }

        if enabled {
            hp.setHighPass(freq: s.highPassHz, sampleRate: sampleRate)
            lowShelf.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: sampleRate)
            highShelf.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: sampleRate)
            comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio,
                           attackMs: s.compAttackMs, releaseMs: s.compReleaseMs,
                           makeupDb: s.compMakeupDb, sampleRate: sampleRate)
        }

        if clarity != .off {
            presence.setPeaking(freq: ClarityProfile.presenceHz, gainDb: clarity.presenceDb,
                                sampleRate: sampleRate, q: ClarityProfile.presenceQ)
            deEsser.configure(crossoverHz: ClarityProfile.deEssCrossoverHz,
                              thresholdDb: ClarityProfile.deEssThresholdDb,
                              maxReductionDb: clarity.deEssMaxReductionDb,
                              attackMs: ClarityProfile.deEssAttackMs,
                              releaseMs: ClarityProfile.deEssReleaseMs,
                              sampleRate: sampleRate, enabled: true)
        } else {
            presence.setBypass()
            deEsser.configure(crossoverHz: ClarityProfile.deEssCrossoverHz,
                              thresholdDb: ClarityProfile.deEssThresholdDb, maxReductionDb: 0,
                              attackMs: ClarityProfile.deEssAttackMs,
                              releaseMs: ClarityProfile.deEssReleaseMs,
                              sampleRate: sampleRate, enabled: false)
        }

        if mouthNoise != .off {
            dePlosive.configure(
                splitHz: MouthNoiseProfile.plosiveSplitHz,
                surgeRatio: MouthNoiseProfile.plosiveSurgeRatio,
                dominance: MouthNoiseProfile.plosiveDominance,
                floorDb: MouthNoiseProfile.plosiveFloorDb,
                maxReductionDb: mouthNoise.maxPlosReductionDb,
                attackMs: MouthNoiseProfile.plosiveAttackMs,
                releaseMs: MouthNoiseProfile.plosiveReleaseMs,
                sampleRate: sampleRate, enabled: true)
            deClick.configure(
                peakReleaseMs: MouthNoiseProfile.clickPeakReleaseMs,
                slowAttackMs: MouthNoiseProfile.clickSlowAttackMs,
                slowReleaseMs: MouthNoiseProfile.clickSlowReleaseMs,
                clickRatio: MouthNoiseProfile.clickRatio,
                minThresholdDb: MouthNoiseProfile.clickMinThresholdDb,
                holdMs: MouthNoiseProfile.clickHoldMs,
                releaseMs: MouthNoiseProfile.clickReleaseMs,
                maxClickMs: MouthNoiseProfile.clickMaxClickMs,
                gainFloor: mouthNoise.clickGainFloor,
                sampleRate: sampleRate, enabled: true)
        } else {
            dePlosive.configure(splitHz: MouthNoiseProfile.plosiveSplitHz,
                                surgeRatio: MouthNoiseProfile.plosiveSurgeRatio,
                                dominance: MouthNoiseProfile.plosiveDominance,
                                floorDb: MouthNoiseProfile.plosiveFloorDb,
                                maxReductionDb: 0, attackMs: MouthNoiseProfile.plosiveAttackMs,
                                releaseMs: MouthNoiseProfile.plosiveReleaseMs,
                                sampleRate: sampleRate, enabled: false)
            deClick.configure(peakReleaseMs: MouthNoiseProfile.clickPeakReleaseMs,
                              slowAttackMs: MouthNoiseProfile.clickSlowAttackMs,
                              slowReleaseMs: MouthNoiseProfile.clickSlowReleaseMs,
                              clickRatio: MouthNoiseProfile.clickRatio,
                              minThresholdDb: MouthNoiseProfile.clickMinThresholdDb,
                              holdMs: MouthNoiseProfile.clickHoldMs,
                              releaseMs: MouthNoiseProfile.clickReleaseMs,
                              maxClickMs: MouthNoiseProfile.clickMaxClickMs,
                              gainFloor: 1.0, sampleRate: sampleRate, enabled: false)
        }

        if voiceGate != .off {
            gate.configure(marginDb: voiceGate.marginDb, absoluteFloorDb: voiceGate.absoluteFloorDb,
                           hysteresisDb: voiceGate.hysteresisDb, floorDb: voiceGate.floorDb,
                           attackMs: VoiceGateProfile.attackMs, holdMs: voiceGate.holdMs,
                           releaseMs: VoiceGateProfile.releaseMs,
                           envAttackMs: VoiceGateProfile.envAttackMs,
                           envReleaseMs: VoiceGateProfile.envReleaseMs,
                           peakAttackMs: VoiceGateProfile.peakAttackMs,
                           peakReleaseMs: VoiceGateProfile.peakReleaseMs,
                           sampleRate: sampleRate, enabled: true)
        } else {
            gate.configure(marginDb: 0, absoluteFloorDb: -100, hysteresisDb: 0, floorDb: 0,
                           attackMs: VoiceGateProfile.attackMs, holdMs: 0,
                           releaseMs: VoiceGateProfile.releaseMs,
                           envAttackMs: VoiceGateProfile.envAttackMs,
                           envReleaseMs: VoiceGateProfile.envReleaseMs,
                           peakAttackMs: VoiceGateProfile.peakAttackMs,
                           peakReleaseMs: VoiceGateProfile.peakReleaseMs,
                           sampleRate: sampleRate, enabled: false)
        }

        // Limiter runs ONLY when a limiter-owning path is active (polish, clarity, or
        // loudness normalization). The de-plosive/de-click/gate stages are attenuation-only, so
        // mouth-noise-only or gate-only mode needs no limiter — running it would clamp a loud
        // CLEAN sample above the ceiling purely because the feature is on (an identity violation).
        if enabled || clarity != .off || loudnessActive {
            limiter.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: sampleRate)
        }
    }

    /// Clear all filter/dynamics state. Called on the inactive→active
    /// transition (and available for engine restart). Never called per buffer.
    public func reset() {
        hp.reset(); lowShelf.reset(); highShelf.reset()
        presence.reset(); deEsser.reset()
        dePlosive.reset(); deClick.reset()
        gate.reset()
        comp.reset(); limiter.reset()
    }

    public var isEnabled: Bool { enabled }
    public var isActive: Bool { active }

    /// Set the loudness make-up gain. Plain scalar store — cheaper than a full
    /// configure; called from the main-thread loudness timer.
    public func setLoudnessGain(_ g: Float) { loudnessGain = g }

    /// Process `count` samples in place. No-op when inactive. Order:
    /// HP → shelves → presence → de-esser → de-plosive → de-click → gate → compressor → loudness gain → limiter.
    /// Polish stages run only when `enabled`; clarity stages only when `clarity != .off`;
    /// mouth-noise stages only when `mouthNoise != .off`; the gate only when `voiceGate != .off`;
    /// loudness gain only when normalization is active.
    /// The limiter runs only for a limiter-owning path (polish, clarity, or loudness) — the
    /// attenuation-only mouth-noise and gate stages never raise level, so mouth-noise-only or
    /// gate-only mode is a true identity at rest for clean input.
    public func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        guard active else { return }
        let doPolish   = enabled
        let doClarity  = clarity != .off
        let doMouth    = mouthNoise != .off
        let doGate     = voiceGate != .off
        let doLoudness = loudnessActive
        for i in 0..<count {
            var x = buffer[i]
            if doPolish {
                x = hp.process(x)
                x = lowShelf.process(x)
                x = highShelf.process(x)
            }
            if doClarity {
                x = presence.process(x)
                x = deEsser.process(x)
            }
            if doMouth {
                x = dePlosive.process(x)
                x = deClick.process(x)
            }
            if doGate {
                x = gate.process(x)
            }
            if doPolish {
                x = comp.process(x)
            }
            if doLoudness {
                x *= loudnessGain
            }
            // Limiter runs ONLY for limiter-owning paths. Mouth-noise-only mode must NOT limit
            // because limiting a loud clean sample would break identity at rest.
            if doPolish || doClarity || doLoudness {
                x = limiter.process(x)
            }
            buffer[i] = x
        }
    }
}
