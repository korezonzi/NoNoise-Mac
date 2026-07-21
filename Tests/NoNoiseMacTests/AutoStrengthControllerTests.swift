import XCTest
@testable import Core

/// Headless tests for `.auto`'s dynamic stage logic. Pure struct + static functions, no
/// `AudioModel`/CoreAudio — same testing posture as `SmartLevelControllerTests`.
final class AutoStrengthControllerTests: XCTestCase {

    private let quietInputLevel: Float = 0.05    // above the silence floor — normal room tone
    private let noisyInputLevel: Float = 0.3

    // MARK: - Convergence

    /// A sustained quiet room (low AI activity — nothing to suppress) settles at `.weak`.
    func testQuietRoomConvergesToWeak() {
        var state = AutoStrengthController.State()   // starts at .medium
        var sawChangeToWeak = false
        for _ in 0..<200 {
            let (next, decision) = AutoStrengthController.evaluate(
                state: state, aiActivity: 0.02, inputLevel: quietInputLevel, isAIEnabled: true)
            state = next
            if decision.didChange && decision.targetStage == .weak { sawChangeToWeak = true }
        }
        XCTAssertEqual(state.currentStage, .weak, "a sustained quiet room must settle at .weak")
        XCTAssertTrue(sawChangeToWeak, "the hysteresis window must have actually closed on .weak")
    }

    /// A sustained noisy room (high AI activity — constantly suppressing) settles at `.strong`.
    func testNoisyRoomConvergesToStrong() {
        var state = AutoStrengthController.State()   // starts at .medium
        for _ in 0..<1500 {
            let (next, _) = AutoStrengthController.evaluate(
                state: state, aiActivity: 1.0, inputLevel: noisyInputLevel, isAIEnabled: true)
            state = next
        }
        XCTAssertEqual(state.currentStage, .strong, "a sustained noisy room must settle at .strong")
    }

    // MARK: - Hysteresis / anti-flicker

    /// The EMA sitting right at a threshold and drifting a hair either side every tick must NEVER
    /// flip the stage — a raw-stage change needs `stageHoldTicks` CONSECUTIVE ticks, and this
    /// oscillation never sustains more than one.
    func testBoundaryOscillationNeverChangesStage() {
        var state = AutoStrengthController.State(
            emaActivity: AutoStrengthController.weakUpperBound, currentStage: .medium)
        for i in 0..<300 {
            let activity: Float = (i % 2 == 0) ? 0.0 : 1.0   // alternate hard either side of the boundary
            let (next, decision) = AutoStrengthController.evaluate(
                state: state, aiActivity: activity, inputLevel: quietInputLevel, isAIEnabled: true)
            state = next
            XCTAssertFalse(decision.didChange, "boundary flicker must never close the hysteresis window")
        }
        XCTAssertEqual(state.currentStage, .medium, "must remain at the untouched starting stage")
    }

    /// A short (~2 s), realistic activity burst from a stable baseline barely moves the 30 s-time-
    /// constant EMA at all — it never even crosses out of the current zone, so no candidate stage
    /// is ever considered, let alone committed. This is the EMA's own inertia doing the "ignore a
    /// brief spike" job before the explicit hold-time hysteresis is even needed.
    func testShortRealisticSpikeNeverCrossesThreshold() {
        var state = AutoStrengthController.State(emaActivity: 0.20, currentStage: .medium)
        let spikeTicks = 60   // ~2.4 s at 25 Hz — comfortably under the 3 s hold time
        for _ in 0..<spikeTicks {
            let (next, decision) = AutoStrengthController.evaluate(
                state: state, aiActivity: 1.0, inputLevel: noisyInputLevel, isAIEnabled: true)
            state = next
            XCTAssertFalse(decision.didChange, "a short spike must never commit a stage change")
            XCTAssertNil(state.candidateStage, "a short spike must not even raise a candidate")
        }
        XCTAssertEqual(state.currentStage, .medium)
    }

    /// A LONGER burst that does drift the EMA across a boundary — so a candidate stage genuinely
    /// starts timing toward `.strong` — but reverts to baseline before the ~3 s hold time elapses.
    /// The partially-elapsed candidate must be abandoned (reset to nil), never committed, once the
    /// EMA settles back into the current zone.
    func testPartialCandidateWindowAbandonedOnRevertBeforeCommit() {
        var state = AutoStrengthController.State(emaActivity: 0.30, currentStage: .medium)

        // Long enough for the EMA to cross the .strong boundary (~56 ticks) plus a further margin
        // of candidate ticks (~20) — comfortably short of the 75-tick hold time.
        for _ in 0..<76 {
            let (next, decision) = AutoStrengthController.evaluate(
                state: state, aiActivity: 1.0, inputLevel: noisyInputLevel, isAIEnabled: true)
            state = next
            XCTAssertFalse(decision.didChange, "must not commit before the hold time elapses")
        }
        XCTAssertEqual(state.candidateStage, .strong, "a candidate must be actively timing by now")
        XCTAssertLessThan(state.candidateTicks, AutoStrengthController.stageHoldTicks,
                          "must still be short of the commit threshold")

        // Revert to the quiet baseline. The EMA must fall back under the boundary well before the
        // accumulated candidate ticks reach the hold time, abandoning the candidate.
        var candidateWasAbandoned = false
        for _ in 0..<80 {
            let (next, decision) = AutoStrengthController.evaluate(
                state: state, aiActivity: 0.02, inputLevel: quietInputLevel, isAIEnabled: true)
            state = next
            XCTAssertFalse(decision.didChange, "an abandoned candidate must never retroactively commit")
            if state.candidateStage == nil { candidateWasAbandoned = true; break }
        }
        XCTAssertTrue(candidateWasAbandoned, "the candidate must reset once the EMA re-entered .medium")
        XCTAssertEqual(state.currentStage, .medium, ".auto must never have left .medium for the reverted burst")
    }

    // MARK: - AI off

    /// While AI is off there is no suppression-confidence signal to read — `evaluate` must be a
    /// complete no-op (state AND decision both untouched), regardless of the other inputs.
    func testAIOffIsANoOp() {
        let state = AutoStrengthController.State(emaActivity: 0.5, currentStage: .strong)
        let (next, decision) = AutoStrengthController.evaluate(
            state: state, aiActivity: 1.0, inputLevel: noisyInputLevel, isAIEnabled: false)
        XCTAssertEqual(next, state, "state must be untouched while AI is off")
        XCTAssertEqual(decision.targetStage, .strong)
        XCTAssertFalse(decision.didChange)
    }

    // MARK: - Silence floor (inputLevel gating)

    /// Near-total silence (mic muted/disconnected, trimmed RMS below the silence floor) must
    /// freeze the EMA rather than let hardware silence pull the noise-floor estimate down.
    func testNearSilentInputFreezesTheEMA() {
        let state = AutoStrengthController.State(emaActivity: 0.4, currentStage: .strong)
        let (next, _) = AutoStrengthController.evaluate(
            state: state, aiActivity: 0.0, inputLevel: 0.0, isAIEnabled: true)
        XCTAssertEqual(next.emaActivity, state.emaActivity, accuracy: 1e-9,
                      "silent input must not move the EMA at all")
    }

    /// An ordinary conversational pause (well above the silence floor) keeps updating normally.
    func testOrdinaryPauseAboveSilenceFloorStillUpdates() {
        let state = AutoStrengthController.State(emaActivity: 0.4, currentStage: .strong)
        let (next, _) = AutoStrengthController.evaluate(
            state: state, aiActivity: 0.0, inputLevel: quietInputLevel, isAIEnabled: true)
        XCTAssertNotEqual(next.emaActivity, state.emaActivity,
                          "room-noise-level input must still update the EMA")
    }

    // MARK: - Stage → VoicePreset mapping (single source of truth)

    func testStageParametersMatchFixedPresets() {
        XCTAssertEqual(AutoStrengthController.Stage.weak.suppressionStrength,
                       VoicePreset.weak.parameters!.suppressionStrength)
        XCTAssertEqual(AutoStrengthController.Stage.weak.attenuationLimitDb,
                       VoicePreset.weak.parameters!.attenuationLimitDb)
        XCTAssertEqual(AutoStrengthController.Stage.medium.suppressionStrength,
                       VoicePreset.medium.parameters!.suppressionStrength)
        XCTAssertEqual(AutoStrengthController.Stage.medium.attenuationLimitDb,
                       VoicePreset.medium.parameters!.attenuationLimitDb)
        XCTAssertEqual(AutoStrengthController.Stage.strong.suppressionStrength,
                       VoicePreset.strong.parameters!.suppressionStrength)
        XCTAssertEqual(AutoStrengthController.Stage.strong.attenuationLimitDb,
                       VoicePreset.strong.parameters!.attenuationLimitDb)
    }
}
