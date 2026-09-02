import Foundation

/// Centralizes the fixed DSP-pipeline latency budget so every consumer (main playback,
/// `IncomingCleanupEngine`, `SpeakerCleanupEngine`) references ONE constant instead of a repeated
/// magic number. Values are unchanged from the pre-refactor hardcoded literals — this is a pure
/// extraction, not a behavior change.
public enum AudioLatency {
    /// The pipeline's fixed sample rate. Shared by the latency math below and by
    /// `AVCaptureMicBackend`'s capture-side target format (was a separate `48000.0` literal).
    public static let sampleRate: Double = 48_000

    /// Ring-buffer read-side target, in samples @ `sampleRate` (= 50 ms). Render/consumer callbacks
    /// drop any backlog beyond this so audio never plays back a large buffered delay.
    public static let ringTargetFrames = 2400

    /// One DeepFilterNet3 STFT hop, in samples @ `sampleRate`.
    public static let stftFrames = 960

    /// Total added latency in milliseconds: `(ringTargetFrames + stftFrames) / sampleRate`.
    /// Reported (not measured) via `AudioModel.addedLatencyMs`.
    public static var addedMs: Float {
        Float(ringTargetFrames + stftFrames) / Float(sampleRate) * 1000
    }
}
