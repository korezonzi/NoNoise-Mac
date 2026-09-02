import Foundation

/// A device the user can pick as the mic-capture source. `uid` is the stable HAL/AVCapture
/// identifier (`AVCaptureDevice.uniqueID` == `kAudioDevicePropertyDeviceUID`); `name` is the
/// display name. Pure value type — no CoreAudio/AVFoundation dependency — so it can be shared by
/// `AudioModel`, the UI, and the CLI without pulling AVCapture types past the backend boundary.
public struct MicDevice: Identifiable, Equatable {
    public let uid: String
    public let name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// A single mic-capture producer, behind a protocol so `AudioModel` can be handed a different
/// implementation without changing its own logic (Phase 1 ships `AVCaptureMicBackend`, moved
/// unchanged from the pre-refactor AVCaptureSession pipeline; Phase 2 adds a second backend built
/// on Apple Voice Processing I/O). Exactly ONE backend is active at a time — the `t*` telemetry
/// scalars downstream of `AudioModel.ingest(_:count:)` assume a single producer.
public protocol MicCaptureBackend: AnyObject {
    /// Delivers normalized mono / 48 kHz / Float32 audio. Called on a backend-owned, NON-realtime
    /// serial queue (never the audio render thread). The pointer is valid only for the duration of
    /// the call — the callee may read and mutate the buffer in place (e.g. an input-volume trim)
    /// but must not retain it past return.
    var onAudio: ((UnsafeMutablePointer<Float>, Int) -> Void)? { get set }

    /// Rebuild capture for the given device UID. Returns `true` iff an input was actually
    /// attached (device resolved AND the session accepted it) — the caller uses this to decide
    /// whether calling `start()` makes sense. Does NOT auto-start either way — the owner drives
    /// `start()`/`stop()` separately (e.g. the on-demand "NoNoise Mic in use" gate).
    @discardableResult
    func configure(deviceUID: String) -> Bool

    /// Start capturing. A no-op if already running.
    func start()

    /// Stop capturing. A no-op if already stopped.
    func stop()

    /// Whether the backend is currently capturing.
    var isRunning: Bool { get }
}
