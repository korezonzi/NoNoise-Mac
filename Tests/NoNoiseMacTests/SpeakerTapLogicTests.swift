import XCTest
import CoreAudio
@testable import Core

/// Host unit tests for the pure, ungated decisions behind the direct-hidden-input Speaker Cleanup
/// path (`SpeakerTapLogic`). No macOS version gate and no CoreAudio device objects are needed here —
/// mirrors `IncomingTapLogicTests`' "risky decisions live in tested statics" discipline.
final class SpeakerTapLogicTests: XCTestCase {

    // MARK: Tap device resolution validity

    func testValidTapDeviceRequiresNonZeroRealID() {
        XCTAssertTrue(SpeakerTapLogic.isValidTapDevice(id: AudioObjectID(7)))
    }

    func testInvalidWhenTapDeviceIsZero() {
        XCTAssertFalse(SpeakerTapLogic.isValidTapDevice(id: AudioObjectID(0)))
    }

    func testInvalidWhenTapDeviceIsUnknown() {
        XCTAssertFalse(SpeakerTapLogic.isValidTapDevice(id: AudioObjectID(kAudioObjectUnknown)))
    }

    // MARK: Canonical stream format validation (48 kHz / 2 ch / Float32 interleaved)

    func testExpectedFormatAccepts48kStereoFloatInterleaved() {
        XCTAssertTrue(SpeakerTapLogic.isExpectedFormat(sampleRate: 48000, channelCount: 2,
                                                        isFloat: true, isInterleaved: true))
    }

    func testExpectedFormatToleratesTinySampleRateJitter() {
        // Real hardware read-backs can be off by a fraction of a Hz.
        XCTAssertTrue(SpeakerTapLogic.isExpectedFormat(sampleRate: 48000.0001, channelCount: 2,
                                                        isFloat: true, isInterleaved: true))
    }

    func testExpectedFormatRejectsWrongSampleRate() {
        XCTAssertFalse(SpeakerTapLogic.isExpectedFormat(sampleRate: 44100, channelCount: 2,
                                                         isFloat: true, isInterleaved: true))
    }

    func testExpectedFormatRejectsWrongChannelCount() {
        XCTAssertFalse(SpeakerTapLogic.isExpectedFormat(sampleRate: 48000, channelCount: 1,
                                                         isFloat: true, isInterleaved: true))
    }

    func testExpectedFormatRejectsNonFloat() {
        XCTAssertFalse(SpeakerTapLogic.isExpectedFormat(sampleRate: 48000, channelCount: 2,
                                                         isFloat: false, isInterleaved: true))
    }

    func testExpectedFormatRejectsNonInterleaved() {
        XCTAssertFalse(SpeakerTapLogic.isExpectedFormat(sampleRate: 48000, channelCount: 2,
                                                         isFloat: true, isInterleaved: false))
    }

    // MARK: Playback-destination repin decision (self-loop guard)

    func testRepinWhenGenuineOutputAndNotSelf() {
        XCTAssertEqual(SpeakerTapLogic.repinDecision(hasOutputDevice: true, isSelfLoop: false), .repin)
    }

    func testRejectSelfLoopWhenDefaultOutputIsOwnSpeaker() {
        XCTAssertEqual(SpeakerTapLogic.repinDecision(hasOutputDevice: true, isSelfLoop: true),
                       .rejectSelfLoop)
    }

    func testRejectNoOutputWhenNoDeviceResolved() {
        // A missing default output takes precedence over the self-loop check (there's nothing to
        // evaluate self-loop against).
        XCTAssertEqual(SpeakerTapLogic.repinDecision(hasOutputDevice: false, isSelfLoop: false),
                       .rejectNoOutput)
        XCTAssertEqual(SpeakerTapLogic.repinDecision(hasOutputDevice: false, isSelfLoop: true),
                       .rejectNoOutput)
    }

    // MARK: Mutual exclusion (Speaker Cleanup vs Incoming Cleanup)

    func testForcesOtherOffWhenTurningOnWhileOtherEnabled() {
        XCTAssertTrue(SpeakerTapLogic.shouldForceOtherOff(turningOn: true, otherEnabled: true))
    }

    func testDoesNotForceOffWhenTurningOnWhileOtherAlreadyDisabled() {
        XCTAssertFalse(SpeakerTapLogic.shouldForceOtherOff(turningOn: true, otherEnabled: false))
    }

    func testDoesNotForceOffWhenTurningOff() {
        // Turning a toggle OFF must never reach in and disable the sibling feature.
        XCTAssertFalse(SpeakerTapLogic.shouldForceOtherOff(turningOn: false, otherEnabled: true))
        XCTAssertFalse(SpeakerTapLogic.shouldForceOtherOff(turningOn: false, otherEnabled: false))
    }
}
