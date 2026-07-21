import Foundation

/// Pure decision logic for the `.auto` noise preset: continuously estimates how much background
/// noise is present (from the DSP's own `aiActivity` confidence signal — "how much is the AI
/// removing right now") and steps the effective suppression strength through the SAME fixed
/// stages as the `.weak` / `.medium` / `.strong` presets. A quiet room settles toward `.weak`
/// (less processing, more natural tone); a noisy room settles toward `.strong` (maximum
/// suppression) — without the user ever having to pick a preset.
///
/// Design mirrors `SmartLevelController`: a stateless enum of pure static functions. The caller
/// (`AudioModel`) owns the mutable `State` value across ticks and feeds it back in on the next
/// call — so this is fully headless-testable with no `AudioModel`/CoreAudio dependency.
public enum AutoStrengthController {

    // MARK: - Tunables

    /// Long time-constant EMA so a single sentence, a breath, or a brief silence never flips the
    /// stage — only a sustained change in the room's noise floor does. ~30 s is long enough that
    /// DeepFilterNetDSP's per-hop `aiActivity` (which swings with every voiced/unvoiced/silence
    /// transition) is fully smoothed into a stable "how noisy is this room, on average" score.
    public static let emaTimeConstantSeconds: Float = 30.0

    /// Matches the always-on control pump's cadence (`AudioModel.startControlPump`, 0.04 s / 25 Hz)
    /// — `evaluate` is expected to be called exactly once per pump tick.
    public static let tickIntervalSeconds: Float = 0.04

    /// One-pole EMA smoothing factor per tick, `alpha = dt / (tau + dt)`. Computed once as a
    /// documented constant rather than re-derived per call site.
    public static let emaAlpha: Float = tickIntervalSeconds / (emaTimeConstantSeconds + tickIntervalSeconds)

    /// Below this smoothed activity score, the room reads as quiet ⇒ `.weak`.
    public static let weakUpperBound: Float = 0.12
    /// Above this smoothed activity score, the room reads as noisy ⇒ `.strong`. Scores in
    /// `weakUpperBound...strongLowerBound` (inclusive both ends) read as moderate ⇒ `.medium`.
    public static let strongLowerBound: Float = 0.35

    /// Consecutive ticks a NEW stage must be the raw (unfiltered) verdict before it actually takes
    /// effect — ~3 s at the 25 Hz pump cadence. This is the hysteresis: it absorbs both brief
    /// activity spikes AND boundary flicker (the EMA sitting right at 0.12/0.35 and drifting a
    /// hair either side tick-to-tick) so `.auto` never audibly flaps between stages.
    public static let stageHoldTicks: Int = Int((3.0 / tickIntervalSeconds).rounded())  // 75

    /// Below this trimmed-input RMS, treat the tick as "no real signal" (mic muted/disconnected at
    /// the OS level) and freeze the EMA rather than let hardware silence pull the noise-floor
    /// estimate toward `.weak`. An ordinary gap between sentences still carries room-noise RMS
    /// well above this floor, so normal conversational pauses keep updating the EMA normally.
    public static let silenceFloor: Float = 0.0005

    // MARK: - Stage

    /// The fixed stage `.auto` currently occupies. Deliberately a 3-case subset of `VoicePreset`
    /// (never `.auto`/`.custom`), so a target stage can never point back at itself.
    public enum Stage: String, CaseIterable, Sendable, Equatable {
        case weak, medium, strong

        /// The fixed preset carrying this stage's numbers — SINGLE SOURCE OF TRUTH: the DSP
        /// values live once on `VoicePreset.weak`/`.medium`/`.strong`, never duplicated here.
        public var preset: VoicePreset {
            switch self {
            case .weak:   return .weak
            case .medium: return .medium
            case .strong: return .strong
            }
        }

        public var suppressionStrength: Float { preset.parameters!.suppressionStrength }
        public var attenuationLimitDb: Float { preset.parameters!.attenuationLimitDb }
    }

    // MARK: - State (caller-owned, mirrored across ticks)

    /// Mutable state the caller (`AudioModel`) keeps across pump ticks — same idiom as
    /// `SmartLevelController`'s externally-held hot-tick counters. Starts at `.medium`, matching
    /// `VoicePreset.auto`'s initial parameters, until the first real verdict lands.
    public struct State: Equatable {
        public var emaActivity: Float
        public var currentStage: Stage
        /// The raw stage currently being timed for a switch; `nil` once it agrees with `currentStage`.
        public var candidateStage: Stage?
        public var candidateTicks: Int

        public init(emaActivity: Float = 0, currentStage: Stage = .medium,
                    candidateStage: Stage? = nil, candidateTicks: Int = 0) {
            self.emaActivity = emaActivity
            self.currentStage = currentStage
            self.candidateStage = candidateStage
            self.candidateTicks = candidateTicks
        }
    }

    /// One tick's verdict. `didChange` is true ONLY on the exact tick the hysteresis window
    /// closes and the stage actually moved (the new stage is `targetStage`, and is also
    /// reflected in the `state` returned alongside this by `evaluate`).
    public struct AutoDecision: Equatable {
        public let targetStage: Stage
        public let didChange: Bool
    }

    // MARK: - Evaluation

    /// Pure per-tick update. Returns the NEW state to store back (caller mirrors it into its own
    /// `var`, same pattern as `SmartLevelController.evaluateInputGuard`) plus the tick's decision.
    /// `AutoStrengthController` itself holds no state — nothing here is shared/static mutable.
    public static func evaluate(state: State, aiActivity: Float, inputLevel: Float,
                                isAIEnabled: Bool) -> (state: State, decision: AutoDecision) {
        guard isAIEnabled else {
            // No AI running ⇒ no suppression-confidence signal to read. Freeze completely —
            // don't let a stale/zero aiActivity reading pull the EMA down while AI is off.
            return (state, AutoDecision(targetStage: state.currentStage, didChange: false))
        }

        var next = state
        if inputLevel >= silenceFloor {
            next.emaActivity = emaAlpha * aiActivity + (1 - emaAlpha) * state.emaActivity
        }

        let rawStage = stage(forScore: next.emaActivity)

        if rawStage == next.currentStage {
            next.candidateStage = nil
            next.candidateTicks = 0
        } else if rawStage == next.candidateStage {
            next.candidateTicks += 1
        } else {
            next.candidateStage = rawStage
            next.candidateTicks = 1
        }

        var didChange = false
        if let candidate = next.candidateStage, next.candidateTicks >= stageHoldTicks {
            didChange = candidate != next.currentStage
            next.currentStage = candidate
            next.candidateStage = nil
            next.candidateTicks = 0
        }

        return (next, AutoDecision(targetStage: next.currentStage, didChange: didChange))
    }

    private static func stage(forScore score: Float) -> Stage {
        if score < weakUpperBound { return .weak }
        if score <= strongLowerBound { return .medium }
        return .strong
    }
}
