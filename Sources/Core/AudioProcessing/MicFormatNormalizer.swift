import Foundation
import AVFoundation
import AVFAudio

/// Validates `VoiceIOEngine`'s `installTap` buffers before handing them to `AudioModel.ingest()`.
///
/// Review fix M4/M5: this used to resample a non-48k input bus down/up to 48 kHz. That's gone —
/// `VoiceIOEngine.buildAndStart()` now verifies the input bus is genuinely running at 48 kHz BEFORE
/// ever installing the tap (a non-48k bus, e.g. a BT headset, abandons VPIO entirely via
/// `FallbackReason.unsupportedInputRate` — a headset already has no acoustic loop, so the built-in-
/// speaker echo problem this feature targets is structurally absent for it). The tap itself is
/// therefore ALWAYS opened with the spike-proven FIXED format (`AudioUtils.shared.processingFormat`
/// — mono/48 kHz/Float32), matching `AVCaptureMicBackend`'s and the harness's own tap format exactly.
///
/// This type's only remaining job is a per-buffer safety check (M6): a malformed buffer (no channel
/// data, unexpected format) is reported via `onInvalidBuffer` — NEVER silently dropped or fed into
/// the pipeline as garbage.
final class MicFormatNormalizer {
    private let expectedSampleRate: Double
    private let expectedChannelCount: AVAudioChannelCount

    init(expectedSampleRate: Double = AudioLatency.sampleRate, expectedChannelCount: AVAudioChannelCount = 1) {
        self.expectedSampleRate = expectedSampleRate
        self.expectedChannelCount = expectedChannelCount
    }

    /// Pure format check — headless-testable without an `AVAudioPCMBuffer`.
    static func isValidFormat(sampleRate: Double, channelCount: AVAudioChannelCount,
                              expectedSampleRate: Double, expectedChannelCount: AVAudioChannelCount) -> Bool {
        abs(sampleRate - expectedSampleRate) < 1.0 && channelCount == expectedChannelCount
    }

    /// Passes `buffer`'s channel data straight to `onAudio` (zero conversion, zero allocation) if the
    /// format matches expectations; otherwise calls `onInvalidBuffer` and does NOT call `onAudio`.
    func process(_ buffer: AVAudioPCMBuffer, onAudio: (UnsafeMutablePointer<Float>, Int) -> Void,
                onInvalidBuffer: () -> Void) {
        guard MicFormatNormalizer.isValidFormat(sampleRate: buffer.format.sampleRate,
                                                channelCount: buffer.format.channelCount,
                                                expectedSampleRate: expectedSampleRate,
                                                expectedChannelCount: expectedChannelCount),
              let channel = buffer.floatChannelData?[0] else {
            onInvalidBuffer()
            return
        }
        onAudio(channel, Int(buffer.frameLength))
    }
}
