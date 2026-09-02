import XCTest
@testable import Core

/// Guards the Phase 1 capture-backend extraction: `AudioLatency` centralizes literals that were
/// previously hardcoded in AudioModel/IncomingCleanupEngine/SpeakerCleanupEngine — this test locks
/// the values so the extraction stays behavior-invariant.
final class AudioLatencyTests: XCTestCase {
    func testSampleRateMatchesPreRefactorHardcode() {
        XCTAssertEqual(AudioLatency.sampleRate, 48_000)
    }

    func testRingTargetFramesMatchesPreRefactorHardcode() {
        XCTAssertEqual(AudioLatency.ringTargetFrames, 2400)
    }

    func testStftFramesMatchesPreRefactorHardcode() {
        XCTAssertEqual(AudioLatency.stftFrames, 960)
    }

    func testAddedMsMatchesPreRefactorComputation() {
        // Pre-refactor literal: Float(2400 + 960) / 48000.0 * 1000.0 == 70 ms.
        XCTAssertEqual(AudioLatency.addedMs, 70, accuracy: 0.0001)
    }
}
