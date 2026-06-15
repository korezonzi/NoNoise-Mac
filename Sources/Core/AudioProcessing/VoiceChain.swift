import Foundation

/// "Broadcast Voice" intensity. Drives a coupled presence lift + de-esser so the
/// voice sounds clearer/more present while keeping its original identity. `.off`
/// is a true no-op (presence bypassed, de-esser identity).
public enum ClarityLevel: String, CaseIterable, Identifiable, Sendable {
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

    public static let disabled = VoiceChainSettings(
        enabled: false, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 0,
        highShelfHz: 8000, highShelfDb: 0, compThresholdDb: 0, compRatio: 1,
        compAttackMs: 10, compReleaseMs: 120, compMakeupDb: 0, limiterCeilingDb: -1)
}

/// Time-domain voice-shaping chain: high-pass → low-shelf → high-shelf →
/// compressor → limiter. Per-sample, allocation-free. `configure` runs on main;
/// `process` runs on the render thread and no-ops when disabled.
public final class VoiceChain {
    private let sampleRate: Float
    private var hp = Biquad()
    private var lowShelf = Biquad()
    private var highShelf = Biquad()
    private var comp = Compressor()
    private var limiter = Limiter()
    private var enabled = false

    public init(sampleRate: Float = 48000) {
        self.sampleRate = sampleRate
        hp.setBypass(); lowShelf.setBypass(); highShelf.setBypass()
    }

    public func configure(_ s: VoiceChainSettings) {
        let wasEnabled = enabled
        enabled = s.enabled
        guard s.enabled else { return }
        // Clean start when polish turns ON (don't inherit frozen state from a
        // long-disabled period). Switching between two *enabled* presets is
        // intentionally bumpless — keeping z-state/envelopes avoids a click.
        if !wasEnabled { reset() }
        hp.setHighPass(freq: s.highPassHz, sampleRate: sampleRate)
        lowShelf.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: sampleRate)
        highShelf.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: sampleRate)
        comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio,
                       attackMs: s.compAttackMs, releaseMs: s.compReleaseMs,
                       makeupDb: s.compMakeupDb, sampleRate: sampleRate)
        limiter.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: sampleRate)
    }

    /// Clear all filter/dynamics state. Called on the disabled→enabled
    /// transition (and available for engine restart). Never called per buffer.
    public func reset() {
        hp.reset(); lowShelf.reset(); highShelf.reset(); comp.reset(); limiter.reset()
    }

    public var isEnabled: Bool { enabled }

    /// Process `count` samples in place. No-op when disabled.
    public func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        guard enabled else { return }
        for i in 0..<count {
            var x = buffer[i]
            x = hp.process(x)
            x = lowShelf.process(x)
            x = highShelf.process(x)
            x = comp.process(x)
            x = limiter.process(x)
            buffer[i] = x
        }
    }
}
