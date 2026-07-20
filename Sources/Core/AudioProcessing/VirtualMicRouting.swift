import Foundation

/// Pure, headless-testable routing/filtering logic for the NoNoise virtual driver devices: the
/// OUTGOING mic pair ("NoNoise Mic" + hidden "NoNoise Mic Engine") and the INCOMING speaker pair
/// ("NoNoise Speaker" + hidden "NoNoise Speaker Tap"). Operates on plain values (no CoreAudio) so
/// it runs under `swift test`.
///
/// The constants here are the Swift half of the app↔driver shared contract — they MUST stay
/// identical to the driver's C constants (see `Driver/NoNoiseMic/NoNoiseMic.c` and the plan's
/// contract table). A mismatch fails SILENTLY.
public enum VirtualMicRouting {
    // Shared contract — keep identical to the driver's constants.
    public static let visibleDeviceName = "NoNoise Mic"
    public static let engineDeviceName  = "NoNoise Mic Engine"
    public static let visibleDeviceUID  = "NoNoiseMic:visible:48k2ch"
    public static let engineDeviceUID   = "NoNoiseMic:engine:48k2ch"

    // Shared contract — virtual SPEAKER output + its hidden tap (INCOMING path, separate
    // driver device pair from the mic above). Keep identical to the driver's C constants.
    public static let speakerDeviceName    = "NoNoise Speaker"
    public static let speakerDeviceUID     = "NoNoiseSpk:visible:48k2ch"
    public static let speakerTapDeviceName = "NoNoise Speaker Tap"
    public static let speakerTapDeviceUID  = "NoNoiseSpk:tap:48k2ch"

    /// Known virtual sinks we will auto-route to, in priority order. A physical
    /// output is NEVER a fallback (would play cleaned audio aloud, not feed a mic).
    private static let fallbackVirtualSinks = ["BlackHole"]

    public struct DeviceInfo: Equatable {
        public let uid: String
        public let name: String
        public let isHidden: Bool
        public let hasOutput: Bool
        public init(uid: String, name: String, isHidden: Bool, hasOutput: Bool) {
            self.uid = uid; self.name = name; self.isHidden = isHidden; self.hasOutput = hasOutput
        }
    }

    // ---- Canonical predicates (ONE source — used by discovery, picker filtering, AND auto-route) ----

    /// True for our hidden engine device. Matches by UID OR name so a missing/misreported
    /// `kAudioDevicePropertyIsHidden` flag can't leak the engine into the user's picker.
    public static func isNoNoiseEngine(_ d: DeviceInfo) -> Bool {
        d.uid == engineDeviceUID || d.name == engineDeviceName
    }

    /// True for our visible virtual SPEAKER output. Matches by UID OR name (same defensive
    /// pattern as `isNoNoiseEngine`) — this device is NOT hidden (LINE/Meet/etc. must be able
    /// to select it at the HAL level), so the hidden flag alone can't keep it out of the APP's
    /// own picker.
    public static func isNoNoiseSpeaker(_ d: DeviceInfo) -> Bool {
        d.uid == speakerDeviceUID || d.name == speakerDeviceName
    }

    /// An output the user may pick in the APP's own picker: not hidden, not our mic engine,
    /// and not our own virtual speaker. The speaker is excluded here even though it's visible
    /// at the HAL level (LINE/Meet DO see it in their own pickers) — picking it as THIS app's
    /// render destination would feed NoNoise's own output back into its incoming-cleanup tap,
    /// an audio loop. This function only governs NoNoise's own UI, not other apps' pickers.
    public static func isSelectableOutput(_ d: DeviceInfo) -> Bool {
        !d.isHidden && !isNoNoiseEngine(d) && !isNoNoiseSpeaker(d)
    }

    /// UID of the output the engine should render into: the hidden engine device if present,
    /// else a known virtual sink (BlackHole), else nil (do NOT route to a physical output —
    /// surface "install the driver" instead). Returns the device UID — the exact value the
    /// runtime resolves to an AudioObjectID, so the tested predicate IS the runtime predicate.
    public static func preferredOutputUID(from devices: [DeviceInfo]) -> String? {
        if let engine = devices.first(where: isNoNoiseEngine) { return engine.uid }
        if let bh = devices.first(where: { d in fallbackVirtualSinks.contains(where: { d.name.contains($0) }) }) {
            return bh.uid
        }
        return nil
    }

    /// Output devices to show in the app's own picker — hidden + engine excluded.
    public static func visibleOutputs(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter(isSelectableOutput)
    }

    public static func shouldRepinPlaybackAfterHardwareRefresh(
        preferredRouteUID: String?,
        previousOutputDeviceID: UInt32,
        resolvedOutputDeviceID: UInt32
    ) -> Bool {
        preferredRouteUID == engineDeviceUID &&
        resolvedOutputDeviceID != 0 &&
        resolvedOutputDeviceID == previousOutputDeviceID
    }

    /// Remove the virtual mic (and the hidden speaker tap) from a list of input device names
    /// (prevents a feedback loop if the user could otherwise select them as the capture source).
    /// The speaker tap is hidden so it normally wouldn't surface here — excluded defensively,
    /// mirroring how the mic engine is excluded even though it too should already be hidden.
    public static func filterInputs(_ names: [String]) -> [String] {
        names.filter { $0 != visibleDeviceName && $0 != engineDeviceName && $0 != speakerTapDeviceName }
    }
}
