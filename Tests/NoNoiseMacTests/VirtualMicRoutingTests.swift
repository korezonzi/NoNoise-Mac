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
}
