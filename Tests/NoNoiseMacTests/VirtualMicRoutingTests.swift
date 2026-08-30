import XCTest
@testable import Core

final class VirtualMicRoutingTests: XCTestCase {
    // uid is DELIBERATELY distinct from name so UID-based selection is actually exercised
    // (the runtime resolves the returned UID to an AudioObjectID — the name cannot be translated).
    private func dev(_ name: String, uid: String? = nil, hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        .init(uid: uid ?? "uid:\(name)", name: name, isHidden: hidden, hasOutput: true)
    }

    func testAutoRoutePrefersEngineDevice() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.engineDeviceName, uid: VirtualMicRouting.engineDeviceUID, hidden: true),
                    dev("MacBook Speakers")]
        // Returns the engine device's UID (not its name) — the exact value runtime resolves to an ID.
        XCTAssertEqual(VirtualMicRouting.preferredOutputUID(from: list), VirtualMicRouting.engineDeviceUID)
    }

    func testAutoRouteFallsBackToBlackHoleWhenNoEngine() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"), dev("MacBook Speakers")]
        XCTAssertEqual(VirtualMicRouting.preferredOutputUID(from: list), "BH-uid")
    }

    func testAutoRouteNeverPicksPhysicalOutput() {
        // No virtual sink present → must NOT auto-route to a physical device.
        let list = [dev("MacBook Speakers"), dev("USB Headphones")]
        XCTAssertNil(VirtualMicRouting.preferredOutputUID(from: list))
    }

    func testHiddenEngineFilteredFromOutputPicker() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.engineDeviceName, uid: VirtualMicRouting.engineDeviceUID, hidden: true)]
        let visible = VirtualMicRouting.visibleOutputs(from: list).map(\.name)
        XCTAssertFalse(visible.contains(VirtualMicRouting.engineDeviceName))
        XCTAssertTrue(visible.contains("BlackHole 2ch"))
    }

    func testEngineFilteredByUIDEvenIfHiddenFlagMissing() {
        // Guard-pair: if the HAL fails to report kAudioDevicePropertyIsHidden, the engine
        // must STILL be excluded from the picker by its known UID.
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.engineDeviceName, uid: VirtualMicRouting.engineDeviceUID, hidden: false)]
        let visible = VirtualMicRouting.visibleOutputs(from: list).map(\.name)
        XCTAssertFalse(visible.contains(VirtualMicRouting.engineDeviceName))
    }

    func testVirtualMicFilteredFromInputList() {
        let inputs = ["Built-in Microphone", VirtualMicRouting.visibleDeviceName, "USB Mic"]
        let filtered = VirtualMicRouting.filterInputs(inputs)
        XCTAssertFalse(filtered.contains(VirtualMicRouting.visibleDeviceName))
        XCTAssertEqual(filtered, ["Built-in Microphone", "USB Mic"])
    }

    func testHardwareRefreshRepinsEngineEvenWhenSelectedIDIsUnchanged() {
        XCTAssertTrue(VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(
            preferredRouteUID: VirtualMicRouting.engineDeviceUID,
            previousOutputDeviceID: 75,
            resolvedOutputDeviceID: 75
        ))
    }

    func testHardwareRefreshDoesNotForceRepinForBlackHoleWhenSelectedIDIsUnchanged() {
        XCTAssertFalse(VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(
            preferredRouteUID: "BlackHoleUID",
            previousOutputDeviceID: 12,
            resolvedOutputDeviceID: 12
        ))
    }

    // MARK: - playbackRestartAction (AVAudioEngineConfigurationChange recovery for the main engine)
    // macOS stops an AVAudioEngine BEFORE posting the configuration-change notification, so a
    // notification observed while the engine is already running again is self-induced (our own
    // churn repin / setupPlaybackEngine) — restarting again would loop forever. `engineRunning`
    // is therefore the loop-breaking signal, not a pin-target comparison.

    func testConfigChangeSkipsRestartWhileEngineRunning() {
        XCTAssertEqual(VirtualMicRouting.playbackRestartAction(
            engineRunning: true,
            consecutiveFailures: 0
        ), .skip)
    }

    func testConfigChangeRestartsStoppedEngine() {
        XCTAssertEqual(VirtualMicRouting.playbackRestartAction(
            engineRunning: false,
            consecutiveFailures: 0
        ), .restart)
    }

    func testConfigChangeRestartsUpToMaxAttempts() {
        XCTAssertEqual(VirtualMicRouting.playbackRestartAction(
            engineRunning: false,
            consecutiveFailures: 2,
            maxAttempts: 3
        ), .restart)
    }

    func testConfigChangeGivesUpAtMaxAttempts() {
        XCTAssertEqual(VirtualMicRouting.playbackRestartAction(
            engineRunning: false,
            consecutiveFailures: 3
        ), .giveUp)
    }

    func testConfigChangeGivesUpBeyondMaxAttempts() {
        XCTAssertEqual(VirtualMicRouting.playbackRestartAction(
            engineRunning: false,
            consecutiveFailures: 4
        ), .giveUp)
    }

    func testConfigChangeSkipsEvenAfterGivingUp() {
        // `engineRunning` must outrank the failure count: a running engine (e.g. restarted by a
        // later churn repin) resets the streak via `.skip` — the recovery exit out of `.giveUp`.
        XCTAssertEqual(VirtualMicRouting.playbackRestartAction(
            engineRunning: true,
            consecutiveFailures: 5
        ), .skip)
    }

    // MARK: - Speaker/tap shared contract (app↔driver) — regression guard for the literal strings.
    // These assert the exact literal values, not just `VirtualMicRouting.speaker*` round-trips,
    // so an accidental edit to the constant is caught the same way a C-side edit would be.

    func testSpeakerDeviceContractStrings() {
        XCTAssertEqual(VirtualMicRouting.speakerDeviceName, "NoNoise Speaker")
        XCTAssertEqual(VirtualMicRouting.speakerDeviceUID, "NoNoiseSpk:visible:48k2ch")
    }

    func testSpeakerTapDeviceContractStrings() {
        XCTAssertEqual(VirtualMicRouting.speakerTapDeviceName, "NoNoise Speaker Tap")
        XCTAssertEqual(VirtualMicRouting.speakerTapDeviceUID, "NoNoiseSpk:tap:48k2ch")
    }

    // MARK: - isSelectableOutput excludes the virtual speaker

    func testSpeakerFilteredFromOutputPicker() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.speakerDeviceName, uid: VirtualMicRouting.speakerDeviceUID)]
        let visible = VirtualMicRouting.visibleOutputs(from: list).map(\.name)
        XCTAssertFalse(visible.contains(VirtualMicRouting.speakerDeviceName))
        XCTAssertTrue(visible.contains("BlackHole 2ch"))
    }

    func testSpeakerFilteredByUIDEvenIfNameDiffers() {
        // Guard-pair with testEngineFilteredByUIDEvenIfHiddenFlagMissing: the speaker is NOT
        // hidden at the HAL level (LINE/Meet must see it), so `isSelectableOutput` must exclude
        // it by UID/name match, not by the hidden flag.
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.speakerDeviceName, uid: VirtualMicRouting.speakerDeviceUID, hidden: false)]
        let visible = VirtualMicRouting.visibleOutputs(from: list).map(\.name)
        XCTAssertFalse(visible.contains(VirtualMicRouting.speakerDeviceName))
    }

    func testIsSelectableOutputDirectlyRejectsSpeaker() {
        let speaker = dev(VirtualMicRouting.speakerDeviceName, uid: VirtualMicRouting.speakerDeviceUID)
        XCTAssertFalse(VirtualMicRouting.isSelectableOutput(speaker))
    }

    // MARK: - filterInputs excludes the hidden speaker tap

    func testSpeakerTapFilteredFromInputList() {
        let inputs = ["Built-in Microphone", VirtualMicRouting.speakerTapDeviceName, "USB Mic"]
        let filtered = VirtualMicRouting.filterInputs(inputs)
        XCTAssertFalse(filtered.contains(VirtualMicRouting.speakerTapDeviceName))
        XCTAssertEqual(filtered, ["Built-in Microphone", "USB Mic"])
    }

    func testAllVirtualDeviceNamesFilteredFromInputListTogether() {
        let inputs = ["Built-in Microphone",
                      VirtualMicRouting.visibleDeviceName,
                      VirtualMicRouting.engineDeviceName,
                      VirtualMicRouting.speakerTapDeviceName,
                      "USB Mic"]
        let filtered = VirtualMicRouting.filterInputs(inputs)
        XCTAssertEqual(filtered, ["Built-in Microphone", "USB Mic"])
    }

    // MARK: - preferredOutputUID is unchanged by the new speaker constants (engine → BlackHole,
    // never the speaker — the speaker devices aren't a `fallbackVirtualSinks` entry and aren't
    // the mic engine, so their mere presence in the device list must not alter routing).

    func testAutoRouteStillPrefersEngineDeviceWithSpeakerDevicesPresent() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.speakerDeviceName, uid: VirtualMicRouting.speakerDeviceUID),
                    dev(VirtualMicRouting.speakerTapDeviceName, uid: VirtualMicRouting.speakerTapDeviceUID, hidden: true),
                    dev(VirtualMicRouting.engineDeviceName, uid: VirtualMicRouting.engineDeviceUID, hidden: true),
                    dev("MacBook Speakers")]
        XCTAssertEqual(VirtualMicRouting.preferredOutputUID(from: list), VirtualMicRouting.engineDeviceUID)
    }

    func testAutoRouteStillFallsBackToBlackHoleWithSpeakerDevicesPresentAndNoEngine() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.speakerDeviceName, uid: VirtualMicRouting.speakerDeviceUID),
                    dev(VirtualMicRouting.speakerTapDeviceName, uid: VirtualMicRouting.speakerTapDeviceUID, hidden: true),
                    dev("MacBook Speakers")]
        XCTAssertEqual(VirtualMicRouting.preferredOutputUID(from: list), "BH-uid")
    }

    // MARK: - resolveInputDeviceUID (auto / manual input selection)
    // `available` is always assumed already NoNoise-filtered (see `filterInputs`) — membership in
    // it is the loop guard the function relies on, so these tests use plain synthetic UIDs.

    func testInputSelectionManualPrefersSavedUID() {
        XCTAssertEqual(VirtualMicRouting.resolveInputDeviceUID(
            selection: "saved-uid",
            available: ["saved-uid", "other-uid"],
            defaultUID: "other-uid",
            current: "other-uid"
        ), "saved-uid")
    }

    func testInputSelectionManualFallsBackToDefaultWhenSavedMissing() {
        // Saved UID no longer available (device unplugged) → falls through to the system default.
        XCTAssertEqual(VirtualMicRouting.resolveInputDeviceUID(
            selection: "missing-uid",
            available: ["a-uid", "b-uid"],
            defaultUID: "b-uid",
            current: "a-uid"
        ), "b-uid")
    }

    func testInputSelectionAutoFollowsDefault() {
        XCTAssertEqual(VirtualMicRouting.resolveInputDeviceUID(
            selection: VirtualMicRouting.autoInputSelection,
            available: ["a-uid", "b-uid"],
            defaultUID: "b-uid",
            current: "a-uid"
        ), "b-uid")
    }

    func testInputSelectionAutoIgnoresDefaultNotInList() {
        // The system default resolved to something outside our (NoNoise-filtered) list — e.g. it
        // resolved to "NoNoise Mic" itself, which `filterInputs` already excluded. Auto mode must
        // not loop back onto it; stays on the current device instead.
        XCTAssertEqual(VirtualMicRouting.resolveInputDeviceUID(
            selection: VirtualMicRouting.autoInputSelection,
            available: ["a-uid", "b-uid"],
            defaultUID: "not-in-list-uid",
            current: "a-uid"
        ), "a-uid")
    }

    func testInputSelectionFallsBackToCurrentThenFirst() {
        // No default at all → current (still available) wins.
        XCTAssertEqual(VirtualMicRouting.resolveInputDeviceUID(
            selection: VirtualMicRouting.autoInputSelection,
            available: ["a-uid", "b-uid"],
            defaultUID: nil,
            current: "a-uid"
        ), "a-uid")
        // No default AND current no longer available → falls through to the first entry.
        XCTAssertEqual(VirtualMicRouting.resolveInputDeviceUID(
            selection: VirtualMicRouting.autoInputSelection,
            available: ["a-uid", "b-uid"],
            defaultUID: nil,
            current: "gone-uid"
        ), "a-uid")
    }

    func testInputSelectionEmptyListReturnsNil() {
        XCTAssertNil(VirtualMicRouting.resolveInputDeviceUID(
            selection: VirtualMicRouting.autoInputSelection,
            available: [],
            defaultUID: "b-uid",
            current: "a-uid"
        ))
    }
}
