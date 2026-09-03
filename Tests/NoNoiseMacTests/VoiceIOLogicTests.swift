import XCTest
@testable import Core

/// Host unit tests for the pure, ungated decisions behind the VPIO capture backend
/// (`VoiceIOLogic`). Mirrors `IncomingTapLogicTests`'/`SpeakerTapLogicTests`' "risky decisions live
/// in tested statics" pattern — no `AVAudioEngine`/CoreAudio object is constructed anywhere here.
final class VoiceIOLogicTests: XCTestCase {

    // MARK: cleanupRoute — truth table

    func testRouteIsVoiceIOHookOnlyWhenBothActiveAndInUse() {
        XCTAssertEqual(VoiceIOLogic.cleanupRoute(voiceIOActive: true, micInUse: true), .voiceIOHook)
    }

    func testRouteIsOwnEngineWhenVoiceIONotActive() {
        XCTAssertEqual(VoiceIOLogic.cleanupRoute(voiceIOActive: false, micInUse: true), .ownEngine)
    }

    func testRouteIsOwnEngineWhenMicNotInUse() {
        XCTAssertEqual(VoiceIOLogic.cleanupRoute(voiceIOActive: true, micInUse: false), .ownEngine)
    }

    func testRouteIsOwnEngineWhenNeitherActiveNorInUse() {
        XCTAssertEqual(VoiceIOLogic.cleanupRoute(voiceIOActive: false, micInUse: false), .ownEngine)
    }

    func testPlaybackTargetMapping() {
        XCTAssertEqual(CleanupPlaybackRoute.ownEngine.playbackTarget, .ownEngine)
        XCTAssertEqual(CleanupPlaybackRoute.voiceIOHook.playbackTarget, .external)
    }

    // MARK: effectiveStatus — truth table

    func testStatusIsOffWhenDisabledRegardlessOfOtherSignals() {
        XCTAssertEqual(VoiceIOLogic.effectiveStatus(enabled: false, voiceIORunning: true,
                                                    fallbackReason: nil, avCaptureConfigured: true), .off)
        XCTAssertEqual(VoiceIOLogic.effectiveStatus(enabled: false, voiceIORunning: false,
                                                    fallbackReason: .startFailed, avCaptureConfigured: false), .off)
    }

    func testStatusIsActiveWhenEnabledRunningNoFallbackReason() {
        XCTAssertEqual(VoiceIOLogic.effectiveStatus(enabled: true, voiceIORunning: true,
                                                    fallbackReason: nil, avCaptureConfigured: true), .active)
    }

    func testStatusIsFallbackWhenRunningButPinFailed() {
        XCTAssertEqual(VoiceIOLogic.effectiveStatus(enabled: true, voiceIORunning: true,
                                                    fallbackReason: .inputPinFailed, avCaptureConfigured: true),
                      .fallback(.inputPinFailed))
    }

    func testStatusIsFallbackStartFailedWhenNotRunningButAVCaptureWorks() {
        XCTAssertEqual(VoiceIOLogic.effectiveStatus(enabled: true, voiceIORunning: false,
                                                    fallbackReason: nil, avCaptureConfigured: true),
                      .fallback(.startFailed))
    }

    func testStatusIsFallbackWithExplicitReasonWhenNotRunning() {
        XCTAssertEqual(VoiceIOLogic.effectiveStatus(enabled: true, voiceIORunning: false,
                                                    fallbackReason: .runtimeRestartExhausted, avCaptureConfigured: true),
                      .fallback(.runtimeRestartExhausted))
    }

    func testStatusIsFailedWhenNeitherBackendWorks() {
        XCTAssertEqual(VoiceIOLogic.effectiveStatus(enabled: true, voiceIORunning: false,
                                                    fallbackReason: .startFailed, avCaptureConfigured: false), .failed)
    }

    // MARK: inputPinFailureReason

    func testPinFailureReasonOnlySurfacedForManualSelection() {
        XCTAssertEqual(VoiceIOLogic.inputPinFailureReason(isManualSelection: true), .inputPinFailed)
        XCTAssertNil(VoiceIOLogic.inputPinFailureReason(isManualSelection: false))
    }

    // MARK: startFailureAction — transition table

    func testStartFailureActionRetriesBelowMaxAttempts() {
        XCTAssertEqual(VoiceIOLogic.startFailureAction(consecutiveFailures: 0), .retry)
        XCTAssertEqual(VoiceIOLogic.startFailureAction(consecutiveFailures: 2), .retry)
    }

    func testStartFailureActionGivesUpAtMaxAttempts() {
        XCTAssertEqual(VoiceIOLogic.startFailureAction(consecutiveFailures: 3), .giveUp)
        XCTAssertEqual(VoiceIOLogic.startFailureAction(consecutiveFailures: 10), .giveUp)
    }

    func testStartFailureActionRespectsCustomMaxAttempts() {
        XCTAssertEqual(VoiceIOLogic.startFailureAction(consecutiveFailures: 1, maxAttempts: 1), .giveUp)
        XCTAssertEqual(VoiceIOLogic.startFailureAction(consecutiveFailures: 0, maxAttempts: 1), .retry)
    }

    // MARK: CleanupRouteTransition.plan — the S1 review fix's ordering guarantees

    /// First build (no prior engine): just build, no hook/stop steps at all.
    func testPlanFirstBuildOwnEngine() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: nil, to: .ownEngine), [.buildEngine(.ownEngine)])
    }

    func testPlanFirstBuildExternal() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: nil, to: .external),
                       [.buildEngine(.external), .attachHook, .startIO])
    }

    /// Own → external: stop the old own-engine instance, build the new external one, attach its hook,
    /// then start its IO. NO `.detachHook` (nothing was attached before — the OLD engine owned no hook).
    func testPlanOwnToExternal() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: .ownEngine, to: .external),
                       [.stopEngine, .buildEngine(.external), .attachHook, .startIO])
    }

    /// External → own: detach the hook BEFORE stopping/releasing the engine that owns it (the C1
    /// invariant), THEN stop it, THEN build the fresh own-engine instance. No `.attachHook`/`.startIO`
    /// — `.ownEngine`'s `start()` is self-contained.
    func testPlanExternalToOwn() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: .external, to: .ownEngine),
                       [.detachHook, .stopEngine, .buildEngine(.ownEngine)])
    }

    /// Teardown-only (feature disabled/unavailable) from `.ownEngine`: just stop, no hook to detach.
    func testPlanTeardownFromOwnEngine() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: .ownEngine, to: nil), [.stopEngine])
    }

    /// Teardown-only from `.external`: detach the hook BEFORE stopping (C1 invariant), even though
    /// nothing is being rebuilt afterward.
    func testPlanTeardownFromExternal() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: .external, to: nil), [.detachHook, .stopEngine])
    }

    /// Teardown-only when nothing existed: a true no-op.
    func testPlanTeardownWhenAlreadyNil() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: nil, to: nil), [])
    }

    /// Already at the desired target (either mode): no-op — the caller must not tear down and rebuild
    /// an already-correct engine.
    func testPlanNoOpWhenAlreadyAtTarget() {
        XCTAssertEqual(CleanupRouteTransition.plan(from: .ownEngine, to: .ownEngine), [])
        XCTAssertEqual(CleanupRouteTransition.plan(from: .external, to: .external), [])
    }

    /// Structural invariant (review fix C1/H3/H4 regression guard): whenever a plan detaches a hook,
    /// that step comes strictly before any `.stopEngine` step — swept across every from/to
    /// combination this type can produce, not just the individual cases above.
    func testDetachHookAlwaysPrecedesStopEngine() {
        let targets: [CleanupPlaybackTarget?] = [nil, .ownEngine, .external]
        for from in targets {
            for to in targets {
                let steps = CleanupRouteTransition.plan(from: from, to: to)
                guard let detachIndex = steps.firstIndex(of: .detachHook),
                      let stopIndex = steps.firstIndex(of: .stopEngine) else { continue }
                XCTAssertLessThan(detachIndex, stopIndex,
                                  "detachHook must precede stopEngine for from=\(String(describing: from)) to=\(String(describing: to))")
            }
        }
    }

    /// Structural invariant: whenever a plan attaches a hook, that step comes strictly before
    /// `.startIO` (clean playback must be live before the capture engine's tap mute engages).
    func testAttachHookAlwaysPrecedesStartIO() {
        let targets: [CleanupPlaybackTarget?] = [nil, .ownEngine, .external]
        for from in targets {
            for to in targets {
                let steps = CleanupRouteTransition.plan(from: from, to: to)
                guard let attachIndex = steps.firstIndex(of: .attachHook),
                      let startIOIndex = steps.firstIndex(of: .startIO) else { continue }
                XCTAssertLessThan(attachIndex, startIOIndex,
                                  "attachHook must precede startIO for from=\(String(describing: from)) to=\(String(describing: to))")
            }
        }
    }

    /// Structural invariant: `.stopEngine` never appears when there was no prior engine (`from == nil`).
    func testStopEngineNeverAppearsWithoutAPriorEngine() {
        XCTAssertFalse(CleanupRouteTransition.plan(from: nil, to: .ownEngine).contains(.stopEngine))
        XCTAssertFalse(CleanupRouteTransition.plan(from: nil, to: .external).contains(.stopEngine))
        XCTAssertFalse(CleanupRouteTransition.plan(from: nil, to: nil).contains(.stopEngine))
    }

    // MARK: - EchoRiskLogic (built-in-speaker captions)

    /// Full truth table: the warning fires ONLY for cleaning + built-in speaker + AEC inactive —
    /// the one configuration where the far side hears themselves.
    func testWarnBuiltInSpeakerEchoTruthTable() {
        for cleaning in [false, true] {
            for speaker in [false, true] {
                for aec in [false, true] {
                    let expected = cleaning && speaker && !aec
                    XCTAssertEqual(
                        EchoRiskLogic.shouldWarnBuiltInSpeakerEcho(cleaning: cleaning,
                                                                   isBuiltInSpeaker: speaker,
                                                                   voiceIOActive: aec),
                        expected,
                        "cleaning=\(cleaning) speaker=\(speaker) aec=\(aec)")
                }
            }
        }
    }

    /// An active AEC extinguishes the warning even in the previously hazardous configuration.
    func testActiveVoiceIOExtinguishesTheWarning() {
        XCTAssertTrue(EchoRiskLogic.shouldWarnBuiltInSpeakerEcho(cleaning: true, isBuiltInSpeaker: true,
                                                                 voiceIOActive: false))
        XCTAssertFalse(EchoRiskLogic.shouldWarnBuiltInSpeakerEcho(cleaning: true, isBuiltInSpeaker: true,
                                                                  voiceIOActive: true))
    }

    /// Full truth table: the suggestion fires ONLY for AEC active + built-in speaker + cleanup off.
    func testSuggestCleanupOnSpeakerTruthTable() {
        for aec in [false, true] {
            for speaker in [false, true] {
                for off in [false, true] {
                    let expected = aec && speaker && off
                    XCTAssertEqual(
                        EchoRiskLogic.shouldSuggestCleanupOnSpeaker(voiceIOActive: aec,
                                                                    isBuiltInSpeaker: speaker,
                                                                    cleanupOff: off),
                        expected,
                        "aec=\(aec) speaker=\(speaker) cleanupOff=\(off)")
                }
            }
        }
    }

    /// The two captions are mutually exclusive in every reachable state (cleaning == !cleanupOff).
    func testWarnAndSuggestNeverBothVisible() {
        for cleaning in [false, true] {
            for speaker in [false, true] {
                for aec in [false, true] {
                    let warn = EchoRiskLogic.shouldWarnBuiltInSpeakerEcho(cleaning: cleaning,
                                                                          isBuiltInSpeaker: speaker,
                                                                          voiceIOActive: aec)
                    let suggest = EchoRiskLogic.shouldSuggestCleanupOnSpeaker(voiceIOActive: aec,
                                                                              isBuiltInSpeaker: speaker,
                                                                              cleanupOff: !cleaning)
                    XCTAssertFalse(warn && suggest,
                                   "cleaning=\(cleaning) speaker=\(speaker) aec=\(aec)")
                }
            }
        }
    }
}
