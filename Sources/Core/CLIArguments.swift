import Foundation

public struct AudioDenoiseOptions: Equatable {
    public let inputPath: String
    public let outputPath: String
    public let preset: VoicePreset
    public let gain: Float
    public let strength: Float
    public let attenuationDb: Float
    public let shouldOverwrite: Bool

    public init(inputPath: String,
                outputPath: String,
                preset: VoicePreset = .strong,
                gain: Float = 1.0,
                strength: Float = 1.0,
                attenuationDb: Float = VoicePreset.maxAttenuationDb,
                shouldOverwrite: Bool = false) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.preset = preset
        self.gain = gain
        self.strength = strength
        self.attenuationDb = attenuationDb
        self.shouldOverwrite = shouldOverwrite
    }
}

/// The scenarios `VoiceIOSpikeRunner` understands, plus `.all` (runs the other seven in
/// declaration order). `CaseIterable` is the single source of truth for `AECSpikeOptions
/// .validScenarios` and for the runner's own scenario dispatch — see `VoiceIOSpikeScenarioTests`
/// for the equality check that keeps these two in sync.
///
/// The self-echo case is named `selfEcho` (not `self`) purely to dodge the `self` keyword; its
/// raw value — the string actually typed on the command line — is still `"self"`.
public enum AECSpikeScenario: String, CaseIterable, Equatable {
    case all
    case selfEcho = "self"
    case cross
    case format
    case pin
    case agc
    case tap
    case perf
}

/// Options for `--aec-spike <scenario>`, the throwaway-adjacent Apple Voice Processing I/O
/// feasibility harness (see `VoiceIOSpikeRunner`). Kept a plain, `Equatable` value type — same
/// pattern as `AudioDenoiseOptions` — so parsing stays independently unit-testable.
public struct AECSpikeOptions: Equatable {
    /// Derived from `AECSpikeScenario.allCases` — never list scenario names twice.
    public static let validScenarios: Set<String> = Set(AECSpikeScenario.allCases.map { $0.rawValue })

    /// Upper bound accepted for `--spike-duration`. Long enough for the `agc` scenario's fixed
    /// 30s passes plus headroom; short enough to reject a fat-fingered value (e.g. minutes typed
    /// as seconds) before it turns into a many-hour recording.
    public static let maxSpikeDurationSec: Double = 600

    public let scenario: String
    public let outputDir: String
    public let durationSec: Double
    public let inputSelection: String?

    public init(scenario: String,
                outputDir: String = ".",
                durationSec: Double = 10,
                inputSelection: String? = nil) {
        self.scenario = scenario
        self.outputDir = outputDir
        self.durationSec = durationSec
        self.inputSelection = inputSelection
    }
}

public enum CLIMode: Equatable {
    case help
    case live(input: String, output: String, gain: Float)
    case action(String)
    case denoise(AudioDenoiseOptions)
    case aecSpike(AECSpikeOptions)
}

public enum CLIArguments {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case invalidFloat(String, String)
        case invalidPreset(String)
        case invalidSpikeScenario(String)
        case mixedModes
        case missingLiveDevice

        public var description: String {
            switch self {
            case .missingValue(let flag): return "Missing value for \(flag)."
            case .unknownOption(let option): return "Unknown option \(option)."
            case .invalidFloat(let flag, let value): return "Invalid numeric value for \(flag): \(value)."
            case .invalidPreset(let value): return "Unknown preset \(value)."
            case .invalidSpikeScenario(let value):
                let known = AECSpikeOptions.validScenarios.sorted().joined(separator: ", ")
                return "Unknown --aec-spike scenario \(value). Expected one of: \(known)."
            case .mixedModes: return "Choose exactly one mode: live device pipeline, --action, --denoise, or --aec-spike."
            case .missingLiveDevice: return "Missing --in or --out."
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> CLIMode {
        var inputName: String?
        var outputName: String?
        var liveGain: Float = 1.0
        var denoiseGainOverride: Float?
        var actionVerb: String?
        var denoiseInput: String?
        var denoiseOutput: String?
        var preset: VoicePreset = .strong
        var strengthOverride: Float?
        var attenuationDbOverride: Float?
        var shouldOverwrite = false
        var spikeScenario: String?
        var spikeOutputDir = "."
        var spikeDurationSec: Double = 10
        var spikeInputSelection: String?

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                return .help
            case "--in":
                inputName = try value(after: arg, in: arguments, index: &index)
            case "--out":
                outputName = try value(after: arg, in: arguments, index: &index)
            case "--gain":
                let parsedGain = try floatValue(after: arg, in: arguments, index: &index)
                liveGain = parsedGain
                denoiseGainOverride = parsedGain
            case "--action":
                actionVerb = try value(after: arg, in: arguments, index: &index)
            case "--denoise":
                denoiseInput = try value(after: arg, in: arguments, index: &index)
            case "--output":
                denoiseOutput = try value(after: arg, in: arguments, index: &index)
            case "--preset":
                let rawPreset = try value(after: arg, in: arguments, index: &index)
                // Accepts both current names (auto/strong/medium/weak/custom) and the legacy
                // pre-redesign names (meeting/podcast/tutorial) via the shared migration map.
                guard let parsed = VoicePreset.migratingRawValue(rawPreset.lowercased()) else {
                    throw ParseError.invalidPreset(rawPreset)
                }
                preset = parsed
            case "--strength":
                strengthOverride = try floatValue(after: arg, in: arguments, index: &index)
            case "--attenuation-db":
                attenuationDbOverride = try floatValue(after: arg, in: arguments, index: &index)
            case "--overwrite":
                shouldOverwrite = true
            case "--aec-spike":
                let rawScenario = try value(after: arg, in: arguments, index: &index)
                guard let scenario = AECSpikeScenario(rawValue: rawScenario.lowercased()) else {
                    throw ParseError.invalidSpikeScenario(rawScenario)
                }
                spikeScenario = scenario.rawValue
            case "--spike-out":
                spikeOutputDir = try value(after: arg, in: arguments, index: &index)
            case "--spike-duration":
                // Parsed by hand (not via `floatValue`) because it needs stricter validation than
                // "is a number": `Double("nan")`/`Double("inf")` both parse successfully, and an
                // unchecked NaN/negative/zero/huge value later reaches `Int(durationSec * ...)` and
                // `UInt64(durationSec * 1_000_000_000)` in VoiceIOSpikeRunner, which traps at
                // runtime instead of failing gracefully at the CLI boundary.
                let rawDuration = try value(after: arg, in: arguments, index: &index)
                guard let parsedDuration = Double(rawDuration), parsedDuration.isFinite,
                      parsedDuration > 0, parsedDuration <= AECSpikeOptions.maxSpikeDurationSec else {
                    throw ParseError.invalidFloat(arg, rawDuration)
                }
                spikeDurationSec = parsedDuration
            case "--spike-input":
                spikeInputSelection = try value(after: arg, in: arguments, index: &index)
            default:
                throw ParseError.unknownOption(arg)
            }
            index += 1
        }

        let hasLiveMode = inputName != nil || outputName != nil
        let hasActionMode = actionVerb != nil
        let hasDenoiseMode = denoiseInput != nil || denoiseOutput != nil
        let hasSpikeMode = spikeScenario != nil
        if [hasLiveMode, hasActionMode, hasDenoiseMode, hasSpikeMode].filter({ $0 }).count > 1 {
            throw ParseError.mixedModes
        }

        if denoiseOutput != nil, denoiseInput == nil {
            throw ParseError.missingValue("--denoise")
        }

        if let actionVerb { return .action(actionVerb) }
        if let denoiseInput {
            guard let denoiseOutput else { throw ParseError.missingValue("--output") }
            let presetDefaults = preset.parameters ?? (suppressionStrength: Float(1.0),
                                                       attenuationLimitDb: VoicePreset.maxAttenuationDb,
                                                       outputGain: Float(1.0))
            return .denoise(AudioDenoiseOptions(
                inputPath: denoiseInput,
                outputPath: denoiseOutput,
                preset: preset,
                gain: denoiseGainOverride ?? presetDefaults.outputGain,
                strength: strengthOverride ?? presetDefaults.suppressionStrength,
                attenuationDb: attenuationDbOverride ?? presetDefaults.attenuationLimitDb,
                shouldOverwrite: shouldOverwrite
            ))
        }
        if let spikeScenario {
            return .aecSpike(AECSpikeOptions(
                scenario: spikeScenario,
                outputDir: spikeOutputDir,
                durationSec: spikeDurationSec,
                inputSelection: spikeInputSelection
            ))
        }
        guard let inputName, let outputName else { throw ParseError.missingLiveDevice }
        return .live(input: inputName, output: outputName, gain: liveGain)
    }

    private static func value(after flag: String, in arguments: [String], index: inout Int) throws -> String {
        guard index + 1 < arguments.count else { throw ParseError.missingValue(flag) }
        index += 1
        return arguments[index]
    }

    private static func floatValue(after flag: String, in arguments: [String], index: inout Int) throws -> Float {
        let rawValue = try value(after: flag, in: arguments, index: &index)
        guard let value = Float(rawValue) else { throw ParseError.invalidFloat(flag, rawValue) }
        return value
    }
}
