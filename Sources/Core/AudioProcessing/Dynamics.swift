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
