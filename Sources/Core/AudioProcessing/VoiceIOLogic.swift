import Foundation

/// Effective state of the Voice Processing I/O (VPIO) capture backend, surfaced to the UI. Mirrors
/// `IncomingCleanupStatus`/`SpeakerCleanupStatus`'s "never a lying toggle" rule: the toggle binds to
/// THIS, never the raw `mv.voiceProcessing` flag, because a VPIO start can fail (format mismatch,
/// device pin failure, engine start exception) and `AudioModel` then falls back to
/// `AVCaptureMicBackend` — the UI must reflect that, not claim VPIO is active when it isn't.
public enum VoiceIOStatus: Equatable {
    /// User has not enabled the feature (`mv.voiceProcessing == false`). `VoiceIOEngine` is never
    /// constructed in this state.
    case off
    /// VoiceIOEngine is the active capture backend and genuinely running.
    case active
    /// VoiceIOEngine could not be used as-is; `AudioModel` has fallen back to `AVCaptureMicBackend`.
    /// The toggle stays ON (user's request is still `mv.voiceProcessing == true`) so a later retry
    /// (device change, hardware settling, re-toggle) can recover.
    case fallback(FallbackReason)
    /// Enabled, but NEITHER VoiceIOEngine NOR the `AVCaptureMicBackend` fallback could be configured
    /// (e.g. the resolved input device disappeared from both paths). Capture is not running.
    case failed
}

/// Why `VoiceIOStatus` fell back to `AVCaptureMicBackend`. A plain `String` raw value (matches
/// `IncomingCleanupStatus`'s sibling enums) — no `Encodable` conformance needed, this is UI/logic
/// state only, never persisted or serialized.
public enum FallbackReason: String, Equatable {
    /// `VoiceIOEngine.start()` (the initial or a manual-device-change rebuild) returned `false`.
    case startFailed
    /// The engine started and is running, but pinning it to a MANUALLY selected input device failed
    /// (`kAudioOutputUnitProperty_CurrentDevice` failed even through the uninit→set→init cycle) — so
    /// VPIO would silently capture the wrong device. `AVCaptureMicBackend` pins devices reliably, so
    /// this is deliberately treated as a fallback rather than a "keep VPIO on the wrong mic" outcome.
    case inputPinFailed
    /// A runtime restart (default-output change / `.AVAudioEngineConfigurationChange` recovery)
    /// exhausted its retry budget after a previously successful start.
    case runtimeRestartExhausted
    /// The input bus VPIO actually captures from is NOT running at 48 kHz (observed with some BT
    /// headsets — VPIO can force the bus to 16/24 kHz). Rather than resampling, VPIO is abandoned
    /// outright for this device: a BT headset is earphones, which have no acoustic loop to begin
    /// with, so the built-in-speaker echo problem this feature exists for is already structurally
    /// absent — `AVCaptureMicBackend` gives correct pre-Phase-2 behavior instead.
    case unsupportedInputRate
}

/// Which playback route the receive-cleanup engines (`IncomingCleanupEngine` / `SpeakerCleanupEngine`)
/// should render cleaned audio through.
public enum CleanupPlaybackRoute: Equatable {
    /// The cleanup engine renders through its OWN `AVAudioEngine` to the current default output
    /// (pre-Phase-2 behavior, unchanged).
    case ownEngine
    /// The cleanup engine's capture-only pipeline feeds a `CleanupRenderHook` into `VoiceIOEngine`'s
    /// paired output bus, so Apple's own echo canceller (referenced against VPIO's own playback)
    /// cancels NoNoise's re-rendered audio from the mic it is about to re-capture.
    case voiceIOHook

    /// The `CleanupPlaybackTarget` a receive-cleanup engine's initializer must be built with to
    /// realize this route.
    public var playbackTarget: CleanupPlaybackTarget {
        switch self {
        case .ownEngine: return .ownEngine
        case .voiceIOHook: return .external
        }
    }
}

/// Constructor-level counterpart to `CleanupPlaybackRoute`, named from `IncomingCleanupEngine`'s /
/// `SpeakerCleanupEngine`'s own point of view: `.ownEngine` builds a full playback `AVAudioEngine`
/// (today's behavior); `.external` builds ONLY the capture side and exposes a `CleanupRenderHook` for
/// something else (`VoiceIOEngine`) to render.
public enum CleanupPlaybackTarget: Equatable {
    case ownEngine
    case external
}

/// One primitive step in moving a receive-cleanup engine from one playback route to another (or
/// tearing it down). `AudioModel` interprets these against the concrete engine types; this file only
/// encodes the ORDER, which is the part two review findings (C1 use-after-free, H3/H4 dangling
/// callbacks) showed is easy to get wrong by hand.
public enum RouteMutation: Equatable {
    /// Tell `VoiceIOEngine` to stop rendering the CURRENT hook (render silence instead). MUST happen
    /// BEFORE `.stopEngine` whenever the engine being replaced owns the hook (`.external`) — releasing
    /// a hook-owning engine before detaching risks a use-after-free (see `VoiceIOEngine.hookOwner`'s
    /// belt-and-suspenders strong-reference fix, which this ordering backs up).
    case detachHook
    /// Tear down the CURRENT engine instance (`stop()`).
    case stopEngine
    /// Construct a NEW engine instance for `target` (and, for `.ownEngine`, fully start it; for
    /// `.external`, build ONLY the capture side via `prepareCapture()` — the caller starts its IO via
    /// the later `.startIO` step, after `.attachHook` confirms VoiceIOEngine is already rendering it).
    case buildEngine(CleanupPlaybackTarget)
    /// Wire the new (`.external`-only) engine's `CleanupRenderHook` into `VoiceIOEngine` and confirm
    /// it took effect (`VoiceIOEngine.restart(withHook:owner:)` returned `true`). MUST happen BEFORE
    /// `.startIO` — the whole point of the VPIO-hook route is that clean playback is already live
    /// before the capture-only engine's tap mute engages.
    case attachHook
    /// Start the new (`.external`-only) engine's IO (`startIO()` — this is what engages its tap mute).
    case startIO
}

/// Pure, headless-testable ordering for `RouteMutation` sequences — the single source of the two
/// invariants a review found violated by hand-written transition code: a hook is ALWAYS detached
/// before its owning engine is stopped, and a NEW hook is ALWAYS confirmed attached before the new
/// engine's IO (and thus its tap mute) starts. `current`/`target` of `nil` mean "no engine" (disabled
/// / unavailable) — covers first-build, teardown-on-disable, and route-switch-while-enabled with the
/// SAME function, so a route switch always builds directly in the target mode (never
/// `.ownEngine`-then-rebuild — see AGENTS.md's Voice Processing I/O section).
public enum CleanupRouteTransition {
    public static func plan(from current: CleanupPlaybackTarget?, to target: CleanupPlaybackTarget?) -> [RouteMutation] {
        guard current != target else { return [] }
        var steps: [RouteMutation] = []
        if current == .external { steps.append(.detachHook) }
        if current != nil { steps.append(.stopEngine) }
        guard let target else { return steps }   // teardown only (feature disabled/unavailable)
        steps.append(.buildEngine(target))
        if target == .external {
            steps.append(.attachHook)
            steps.append(.startIO)
        }
        return steps
    }
}

/// Pure, headless-testable decisions for the VPIO capture backend and its interaction with the
/// receive-cleanup engines. Kept OUT of `VoiceIOEngine` (no AVAudioEngine/CoreAudio object
/// construction) so `swift test` exercises every branch on any host — mirrors `IncomingTapLogic` /
/// `SpeakerTapLogic`'s "risky decisions live in tested statics" rule.
public enum VoiceIOLogic {

    /// Which playback route the active receive-cleanup engine should use. `.voiceIOHook` only while
    /// VoiceIOEngine is GENUINELY active (not merely enabled — a `.fallback`/`.failed` VoiceIOEngine
    /// has no output bus worth hooking into) AND the mic is actually in use (on-demand gate): outside
    /// an active call there is no echo problem to solve, and keeping VPIO's paired output bus wired
    /// into the cleanup engine 24/7 would light the on-demand mic-in-use indicator for no benefit.
    public static func cleanupRoute(voiceIOActive: Bool, micInUse: Bool) -> CleanupPlaybackRoute {
        (voiceIOActive && micInUse) ? .voiceIOHook : .ownEngine
    }

    /// Combines the raw signals `AudioModel` observes after attempting a VoiceIOEngine start into the
    /// single published `VoiceIOStatus`.
    /// - Parameters:
    ///   - enabled: `mv.voiceProcessing` (the user's request).
    ///   - voiceIORunning: `VoiceIOEngine.isRunning` immediately after a start attempt, OR `true` when
    ///     no start was attempted because the on-demand gate is currently closed (idle is not a
    ///     failure).
    ///   - fallbackReason: non-nil when a specific fallback condition was observed (pin failure,
    ///     runtime exhaustion); `nil` with `voiceIORunning == false` still resolves to `.startFailed`.
    ///   - avCaptureConfigured: whether the `AVCaptureMicBackend` fallback could itself be configured
    ///     for the current device selection — distinguishes a recoverable fallback from total failure.
    public static func effectiveStatus(enabled: Bool, voiceIORunning: Bool,
                                        fallbackReason: FallbackReason?,
                                        avCaptureConfigured: Bool) -> VoiceIOStatus {
        guard enabled else { return .off }
        if voiceIORunning, fallbackReason == nil { return .active }
        guard avCaptureConfigured else { return .failed }
        return .fallback(fallbackReason ?? .startFailed)
    }

    /// Whether a failed input-device pin should be surfaced as `.fallback(.inputPinFailed)`. A pin
    /// failure on the AUTO selection is a non-event (VPIO already tracks the system default input by
    /// itself — no pin was functionally required); only a MANUAL selection actually loses something
    /// (the user's explicit device choice is silently not honored).
    public static func inputPinFailureReason(isManualSelection: Bool) -> FallbackReason? {
        isManualSelection ? .inputPinFailed : nil
    }

    /// What to do after a VoiceIOEngine runtime-restart attempt (default-output change /
    /// `.AVAudioEngineConfigurationChange` recovery) failed. Mirrors
    /// `VirtualMicRouting.playbackRestartAction`'s backoff shape: `.retry` schedules another attempt,
    /// `.giveUp` after `maxAttempts` surfaces `.fallback(.runtimeRestartExhausted)` and hands capture
    /// back to `AVCaptureMicBackend`.
    public enum StartFailureAction: Equatable { case retry, giveUp }

    public static func startFailureAction(consecutiveFailures: Int, maxAttempts: Int = 3) -> StartFailureAction {
        consecutiveFailures >= maxAttempts ? .giveUp : .retry
    }
}

/// Pure decisions for the built-in-speaker echo captions in the incoming card. Before the VPIO
/// AEC existed, "cleanup re-rendering to the built-in speaker" was unconditionally hazardous
/// (knowledge1.md 2026-09-01); with an ACTIVE VoiceIOEngine our own AEC cancels that playback
/// from the mic feed, so the hazard — and the warning — apply only while it is NOT active.
public enum EchoRiskLogic {

    /// The orange warning caption: cleanup is re-rendering to the built-in speaker AND our own
    /// AEC is not active — the only configuration where the far side hears themselves.
    public static func shouldWarnBuiltInSpeakerEcho(cleaning: Bool, isBuiltInSpeaker: Bool,
                                                    voiceIOActive: Bool) -> Bool {
        cleaning && isBuiltInSpeaker && !voiceIOActive
    }

    /// The neutral suggestion caption: AEC is active and the built-in speaker is live, but cleanup
    /// is off — turning cleanup on adds far-side noise removal AND routes ALL far-end playback
    /// through the VPIO output bus, making the AEC reference complete by construction.
    public static func shouldSuggestCleanupOnSpeaker(voiceIOActive: Bool, isBuiltInSpeaker: Bool,
                                                     cleanupOff: Bool) -> Bool {
        voiceIOActive && isBuiltInSpeaker && cleanupOff
    }
}
