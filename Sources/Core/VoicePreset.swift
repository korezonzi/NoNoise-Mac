import Foundation

/// User-facing noise-suppression profiles. `.strong` / `.medium` / `.weak` are fixed presets —
/// each maps to a complete, static set of DSP parameters. `.auto` starts at the SAME numbers as
/// `.medium` (see `parameters` below) but is then driven dynamically: `AudioModel` runs
/// `AutoStrengthController` on every control-pump tick and steps the live suppression
/// strength/attenuation limit toward `.weak`/`.medium`/`.strong` based on how much background
/// noise the room actually has — the user never has to guess which fixed preset fits. `.custom`
/// carries no parameters; the user's manually dialed-in values are kept as-is.
public enum VoicePreset: String, CaseIterable, Identifiable, Sendable {
    case auto
    case strong
    case medium
    case weak
    case custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto:   return "自動"
        case .strong: return "強"
        case .medium: return "中"
        case .weak:   return "弱"
        case .custom: return "カスタム"
        }
    }

    public var iconName: String {
        switch self {
        case .auto:   return "wand.and.stars"
        case .strong: return "flame.fill"
        case .medium: return "person.2.wave.2.fill"
        case .weak:   return "leaf.fill"
        case .custom: return "slider.horizontal.3"
        }
    }

    public static let maxAttenuationDb: Float = 100.0  // "unlimited" sentinel (matches DSP)
    public static let minAttenuationDb: Float = 6.0

    /// DSP parameters applied when this preset is selected. `nil` for `.custom` (the user's own
    /// values are kept). `.auto`'s numbers are its INITIAL values only: `AudioModel` re-derives
    /// them continuously via `AutoStrengthController` once `.auto` is active, and — unlike every
    /// other knob change — that dynamic adjustment is never persisted (only the `.auto` selection
    /// itself is). Values are tunable starting points (perceptual tuning needs listening).
    public var parameters: (suppressionStrength: Float, attenuationLimitDb: Float, outputGain: Float)? {
        switch self {
        case .auto:   return (0.88, 32.0, 1.0)   // == .medium, until AutoStrengthController takes over
        case .strong: return (1.0, VoicePreset.maxAttenuationDb, 1.0)
        case .medium: return (0.88, 32.0, 1.0)
        case .weak:   return (0.75, 20.0, 1.0)
        case .custom: return nil
        }
    }

    /// Voice-polish chain settings — IDENTICAL for every preset (the former Podcast tone-shaping
    /// settings, now shared by all). There is no per-preset disabled gate anymore: the chain's
    /// on/off state is `AudioModel.voicePolishEnabled` (the Voice Polish toggle) alone — see
    /// `AudioModel.applyVoiceChain`'s `(voicePolishEnabled && preset.voiceChain.enabled) || …` gate,
    /// which is now effectively just `voicePolishEnabled` since `enabled` is always true here.
    public var voiceChain: VoiceChainSettings {
        VoiceChainSettings(enabled: true, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 2,
                          highShelfHz: 9000, highShelfDb: 1.5, compThresholdDb: -20, compRatio: 2.5,
                          compAttackMs: 12, compReleaseMs: 150, compMakeupDb: 3, limiterCeilingDb: -1)
    }

    // MARK: - Legacy migration

    /// Maps a legacy (pre-redesign: Meeting/Podcast/Tutorial) raw value to its new equivalent;
    /// any other string (new preset names, or garbage) falls through to plain `init(rawValue:)`.
    /// This is the SINGLE place the old→new preset mapping is defined — both
    /// `AudioModel.loadSettings` (`mv.preset`) and `VoicePreset`'s own `Decodable` conformance
    /// (used when decoding a `VoiceProfile` saved before the redesign) route through this.
    public static func migratingRawValue(_ raw: String) -> VoicePreset? {
        switch raw {
        case "meeting":  return .strong    // full suppression, unlimited attenuation — same numbers
        case "podcast":  return .medium
        case "tutorial": return .weak
        default:         return VoicePreset(rawValue: raw)
        }
    }
}

// MARK: - Codable (routes decode through the legacy-name migration)

extension VoicePreset: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let preset = VoicePreset.migratingRawValue(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown VoicePreset raw value: \(raw)")
        }
        self = preset
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
