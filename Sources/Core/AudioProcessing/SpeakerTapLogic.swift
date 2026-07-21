import Foundation
import CoreAudio

/// Effective state of Speaker Cleanup, surfaced to the UI. The toggle binds to THIS (never the raw
/// persisted flag) — mirrors `IncomingCleanupStatus`'s "never a lying toggle" rule.
public enum SpeakerCleanupStatus: Equatable {
    /// The driver's hidden "NoNoise Speaker Tap" doesn't resolve — the driver isn't installed (or
    /// doesn't expose the speaker pair yet). The toggle is disabled.
    case unavailable
    /// Feature off (user has not enabled it).
    case off
    /// Engine is genuinely running (reading the Tap device + cleaning + playing).
    case cleaning
    /// User enabled it but `start()` returned false (Tap unresolved after all, format mismatch, no
    /// safe playback destination). The toggle stays on so a retry (re-toggle) can recover.
    case failed
}

/// Pure, headless-testable decisions for the direct-hidden-input Speaker Cleanup path. Kept OUT of
/// `SpeakerCleanupEngine` (no CoreAudio object construction, no IOProc, no `@available` gate — unlike
/// `IncomingTapLogic`, this path uses no macOS-14.4-only tap API) so `swift test` exercises the risky
/// decisions on any host. Imports only Foundation + CoreAudio value types.
public enum SpeakerTapLogic {

    /// Validity predicate for the resolved "NoNoise Speaker Tap" `AudioObjectID`
    /// (`kAudioHardwarePropertyTranslateUIDToDevice`). `0` / `kAudioObjectUnknown` means the driver's
    /// speaker pair isn't installed — the engine must not proceed (there is nothing to read from).
    public static func isValidTapDevice(id: AudioObjectID) -> Bool {
        id != 0 && id != AudioObjectID(kAudioObjectUnknown)
    }

    /// Whether a stream format matches the driver's canonical contract: 48 kHz / 2 ch / Float32
    /// interleaved. Feeding anything else into the fixed stereo-interleaved-only downmix would
    /// silently misread the buffer (wrong stride, wrong channel count), so `start()` must refuse
    /// rather than guess.
    public static func isExpectedFormat(sampleRate: Float64, channelCount: UInt32,
                                        isFloat: Bool, isInterleaved: Bool) -> Bool {
        abs(sampleRate - 48000) < 1.0 && channelCount == 2 && isFloat && isInterleaved
    }

    /// What to do about the playback destination, given the current default output.
    public enum RepinAction: Equatable {
        /// A genuine, non-self output is available — connect/pin to it.
        case repin
        /// The default output resolves to our OWN "NoNoise Speaker" — rendering there would feed
        /// our cleaned output straight back into the Tap (infinite self-loop). Must NOT repin here.
        case rejectSelfLoop
        /// No default output device could be resolved at all.
        case rejectNoOutput
    }

    /// Pure repin decision. `hasOutputDevice` = a default output device id was resolved (non-zero);
    /// `isSelfLoop` = that device (or the fallback under evaluation) IS our own "NoNoise Speaker"
    /// (`VirtualMicRouting.isNoNoiseSpeaker`). The engine resolves both booleans via CoreAudio; this
    /// function only encodes the decision so it's testable without any HAL object.
    public static func repinDecision(hasOutputDevice: Bool, isSelfLoop: Bool) -> RepinAction {
        guard hasOutputDevice else { return .rejectNoOutput }
        return isSelfLoop ? .rejectSelfLoop : .repin
    }

    // MARK: - Mutual exclusion (Speaker Cleanup vs Incoming/guest Cleanup)

    /// Both `IncomingCleanupEngine` and `SpeakerCleanupEngine` render their own `AVAudioEngine` to
    /// the CURRENT DEFAULT OUTPUT. Running both at once double-plays cleaned audio into the same
    /// device. `AudioModel` enforces "at most one enabled" by forcing the OTHER toggle off whenever
    /// one is turned on. This is the pure predicate behind that cascade — kept separate from the
    /// `@Published` `didSet`s (which are on `AudioModel`, not headless-testable) so the actual
    /// decision is unit-tested.
    ///
    /// - Parameters:
    ///   - turningOn: `true` when the toggle just being set is transitioning to `true`.
    ///   - otherEnabled: the OTHER toggle's current value (before any cascade).
    /// - Returns: `true` when the caller must force the other toggle to `false`.
    public static func shouldForceOtherOff(turningOn: Bool, otherEnabled: Bool) -> Bool {
        turningOn && otherEnabled
    }
}
