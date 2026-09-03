import XCTest
import AVFoundation
@testable import Core

/// Host unit tests for `MicFormatNormalizer` — reduced (review fix M4/M5) to a pure format
/// validator + passthrough, since `VoiceIOEngine` now verifies the input bus is genuinely at
/// 48 kHz BEFORE ever installing a tap (no resample path to test anymore).
final class MicFormatNormalizerTests: XCTestCase {

    // MARK: isValidFormat (pure static)

    func testValidAt48kHzMono() {
        XCTAssertTrue(MicFormatNormalizer.isValidFormat(sampleRate: 48_000, channelCount: 1,
                                                        expectedSampleRate: 48_000, expectedChannelCount: 1))
    }

    func testValidWithinFloatingPointTolerance() {
        XCTAssertTrue(MicFormatNormalizer.isValidFormat(sampleRate: 48_000.2, channelCount: 1,
                                                        expectedSampleRate: 48_000, expectedChannelCount: 1))
    }

    func testInvalidWrongSampleRate() {
        XCTAssertFalse(MicFormatNormalizer.isValidFormat(sampleRate: 16_000, channelCount: 1,
                                                         expectedSampleRate: 48_000, expectedChannelCount: 1))
    }

    func testInvalidWrongChannelCount() {
        XCTAssertFalse(MicFormatNormalizer.isValidFormat(sampleRate: 48_000, channelCount: 2,
                                                         expectedSampleRate: 48_000, expectedChannelCount: 1))
    }

    // MARK: process — passthrough / invalid-buffer reporting

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount,
                            fill: Float = 1.0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) { channel[i] = fill }
        }
        return buffer
    }

    func testProcessCallsOnAudioForAValidMono48kBuffer() {
        let normalizer = MicFormatNormalizer()
        let buffer = makeBuffer(sampleRate: 48_000, channels: 1, frames: 8, fill: 0.5)

        var audioCalled = false
        var invalidCalled = false
        var deliveredCount = 0
        normalizer.process(buffer, onAudio: { data, count in
            audioCalled = true
            deliveredCount = count
            XCTAssertEqual(data[0], 0.5)
        }, onInvalidBuffer: { invalidCalled = true })

        XCTAssertTrue(audioCalled)
        XCTAssertFalse(invalidCalled)
        XCTAssertEqual(deliveredCount, 8)
    }

    func testProcessReportsInvalidBufferForWrongSampleRate() {
        let normalizer = MicFormatNormalizer()
        let buffer = makeBuffer(sampleRate: 16_000, channels: 1, frames: 8)

        var audioCalled = false
        var invalidCalled = false
        normalizer.process(buffer, onAudio: { _, _ in audioCalled = true },
                           onInvalidBuffer: { invalidCalled = true })

        XCTAssertFalse(audioCalled)
        XCTAssertTrue(invalidCalled)
    }

    func testProcessReportsInvalidBufferForWrongChannelCount() {
        let normalizer = MicFormatNormalizer()
        let buffer = makeBuffer(sampleRate: 48_000, channels: 2, frames: 8)

        var audioCalled = false
        var invalidCalled = false
        normalizer.process(buffer, onAudio: { _, _ in audioCalled = true },
                           onInvalidBuffer: { invalidCalled = true })

        XCTAssertFalse(audioCalled)
        XCTAssertTrue(invalidCalled)
    }

    func testProcessHonorsCustomExpectedFormat() {
        let normalizer = MicFormatNormalizer(expectedSampleRate: 16_000, expectedChannelCount: 2)
        let buffer = makeBuffer(sampleRate: 16_000, channels: 2, frames: 4, fill: 0.25)

        var audioCalled = false
        normalizer.process(buffer, onAudio: { data, count in
            audioCalled = true
            XCTAssertEqual(count, 4)
            XCTAssertEqual(data[0], 0.25)
        }, onInvalidBuffer: { XCTFail("expected a valid buffer") })

        XCTAssertTrue(audioCalled)
    }
}
