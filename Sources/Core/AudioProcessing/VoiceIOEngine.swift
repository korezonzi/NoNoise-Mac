import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
import CoreAudio
import Accelerate
import CTapRing
import CExceptionGuard

/// Raw-pointer-only render hook for the receive-cleanup engines' `.external` (VPIO-hook) playback
/// route. Carries exactly what `VoiceIOEngine.renderCleanup` needs; the only class reference is
/// `Unmanaged` (no retain/release), so the audio render thread that reads this hook makes zero ARC
/// calls — same rule as `IncomingCleanupEngine`/`SpeakerCleanupEngine`'s own render closures. Value
/// type: safe to store behind a raw pointer (`VoiceIOEngine.hookBox`) and swap while the engine is
/// stopped (see `VoiceIOEngine.restart(withHook:owner:)`).
struct CleanupRenderHook {
    let ringPtr: UnsafeMutablePointer<tap_ring>
    let dsp: Unmanaged<DeepFilterNetDSP>
    let levelPtr: UnsafeMutablePointer<Float>
    let latencyTargetFrames: Int
    /// Non-nil ONLY for the Speaker Cleanup path's sustained-silence bypass (skip the CoreML call
    /// when the buffer is already near zero). `nil` ⇒ always run DFN (Incoming Cleanup path).
    let silenceRunCountBox: UnsafeMutablePointer<Int32>?
    let silenceRMSThreshold: Float
    let silenceHoldBuffers: Int32

    init(ringPtr: UnsafeMutablePointer<tap_ring>, dsp: Unmanaged<DeepFilterNetDSP>,
         levelPtr: UnsafeMutablePointer<Float>, latencyTargetFrames: Int,
         silenceRunCountBox: UnsafeMutablePointer<Int32>? = nil,
         silenceRMSThreshold: Float = 0, silenceHoldBuffers: Int32 = 0) {
        self.ringPtr = ringPtr
        self.dsp = dsp
        self.levelPtr = levelPtr
        self.latencyTargetFrames = latencyTargetFrames
        self.silenceRunCountBox = silenceRunCountBox
        self.silenceRMSThreshold = silenceRMSThreshold
        self.silenceHoldBuffers = silenceHoldBuffers
    }
}

/// `MicCaptureBackend` built on Apple Voice Processing I/O (`AVAudioEngine.inputNode.
/// setVoiceProcessingEnabled(true)`). Unlike `AVCaptureMicBackend`, this backend ALSO owns a paired
/// playback graph (VPIO's echo canceller only references audio THIS process plays through its own
/// output bus) — receive-cleanup engines can hook into that bus via `restart(withHook:owner:)` so
/// Apple's AEC cancels NoNoise's own re-rendered playback from the mic it's about to re-capture (see
/// docs/knowledge/knowledge1.md's 2026-09-02 [DECISION] and the approved plan's Phase 2).
///
/// Real-time discipline: the render callback (`renderSource`) and the `installTap` delivery callback
/// are on DIFFERENT threads. `renderSource` is realtime (audio render thread) and captures ONLY a raw
/// pointer (`hookBox`) — no ARC, no allocation, no lock (mirrors `SpeakerCleanupEngine`). The
/// `installTap` callback is NOT realtime (confirmed by the approved plan), so calling into
/// `MicFormatNormalizer`/`self` there is safe, same as `AVCaptureMicBackend.captureOutput`.
///
/// **No output-device pin** (review fix C2): on real hardware, VPIO's `inputNode.audioUnit` and
/// `outputNode.audioUnit` are the SAME underlying duplex Audio Unit instance. Pinning the "output"
/// side after the input pin silently overwrites it, pointing the whole duplex unit at the OUTPUT
/// device (typically the built-in speaker, which has no input channels) — the input pin is lost and
/// capture goes dead. Output simply follows the engine's own default output; a default-output change
/// is caught by the existing `installDefaultOutputListener()` → full `rebuild()`.
final class VoiceIOEngine: MicCaptureBackend {
    // MARK: Tunable constants

    /// Tap buffer-size hint for `installTap` (100 ms @ 48 kHz) — the tap thread is NOT realtime, so
    /// this only affects delivery cadence, matching the proven `VoiceIOSpikeRunner.tapBufferSizeFrames`.
    static let tapBufferSizeFrames: AVAudioFrameCount = 4_800

    /// Fixed connection format for mainMixer → outputNode. `outputNode.outputFormat(forBus: 0)` is
    /// invalid (0 Hz / 0 ch) at connect time and throws an NSException
    /// (`IsFormatSampleRateAndChannelCountValid`) under Voice Processing — see
    /// docs/knowledge/knowledge1.md 2026-09-02 [DECISION]. A fixed standard stereo format sidesteps it.
    static let outputConnectionFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    /// Tolerance (Hz) for comparing the input bus's actual rate against the pipeline's fixed 48 kHz.
    static let sampleRateToleranceHz = 1.0

    /// Backoff schedule for a runtime restart (default-output change / config-change recovery) —
    /// same shape as `AudioModel.scheduleEngineRestart`'s 0.3s → 1s → 3s.
    private static let restartDelays: [TimeInterval] = [0.3, 1.0, 3.0]

    // MARK: MicCaptureBackend

    var onAudio: ((UnsafeMutablePointer<Float>, Int) -> Void)?

    var isRunning: Bool { engine.isRunning }

    /// Whether `desiredInputDeviceUID`'s CURRENT value reflects an explicit user device choice
    /// (`AudioModel.inputDeviceSelection != .auto`) rather than the auto-follow-default resolution.
    /// Kept OUTSIDE the `MicCaptureBackend` protocol (auto/manual is an `AudioModel`-level concept,
    /// not every backend's concern) — `AudioModel` sets this alongside every `configure(deviceUID:)`
    /// call when `VoiceIOEngine` is the active backend.
    var isManualDeviceSelection = false

    /// Set by the most recent `buildAndStart()` — `true` iff an input-device pin was attempted (i.e.
    /// `desiredInputDeviceUID` was NOT the auto-follow-default sentinel) and failed. `AudioModel`
    /// combines this with `isManualDeviceSelection` via `VoiceIOLogic.inputPinFailureReason` right
    /// after `start()`/`configure()` to decide whether to surface `.fallback(.inputPinFailed)`.
    private(set) var lastPinFailed = false

    /// Set on every `buildAndStart()` failure with the SPECIFIC reason, so callers can map it to the
    /// right `FallbackReason` instead of a generic `.startFailed`. `nil` after a successful build.
    private(set) var lastFailureReason: FallbackReason?

    /// Invoked on the main queue when the engine gives up on a runtime restart (default-output /
    /// config-change recovery exhausted its retry budget) OR a tap buffer failed format validation —
    /// mirrors `IncomingCleanupEngine.onRuntimeFailure`. NOT called for a synchronous
    /// `start()`/`configure()` failure (the caller already observes that via `isRunning` right after
    /// the call).
    var onRuntimeFailure: (() -> Void)?

    /// Invoked (synchronously, always on main — every call site already runs there) after EVERY
    /// successful `buildAndStart()`, including internal runtime-restart rebuilds. `AudioModel` uses
    /// this to re-verify a hook-owning cleanup engine's capture side is still alive after a VPIO
    /// rebuild it didn't initiate itself (review fix H5).
    var onRebuilt: (() -> Void)?

    // MARK: Playback + capture graph

    private let engine = AVAudioEngine()
    private var renderSource: AVAudioSourceNode!
    private var renderSourceAttached = false
    /// Raw pointer to the current cleanup render hook (or `nil` = render silence). Written ONLY while
    /// the engine is stopped (`restart(withHook:owner:)`), read every render callback — no lock
    /// needed (structurally zero overlap, see `restart(withHook:owner:)`).
    private let hookBox: UnsafeMutablePointer<CleanupRenderHook?>
    /// Strong reference to whichever receive-cleanup engine currently owns `hookBox`'s hook — keeps
    /// it ALIVE for as long as this engine might render through it, even if `AudioModel` drops its
    /// own reference first (review fix C1: releasing a hook-owning cleanup engine without detaching
    /// its hook first was a use-after-free). Cleared together with the hook itself.
    private var hookOwner: AnyObject?

    private let normalizer = MicFormatNormalizer()
    private var desiredInputDeviceUID: String = VirtualMicRouting.autoInputSelection
    /// The on-demand gate's intent (`start()`/`stop()`), independent of `engine.isRunning`.
    private var wantsRunning = false
    private var consecutiveRestartFailures = 0
    private var restartWorkItem: DispatchWorkItem?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var configObserver: NSObjectProtocol?

    init() {
        hookBox = .allocate(capacity: 1)
        hookBox.initialize(to: nil)

        let box = hookBox
        renderSource = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frameCount)
            guard let hook = box.pointee else {
                data.update(repeating: 0, count: count)   // no cleanup hook yet → silent playback,
                return noErr                                // still required: a record-only VPIO
            }                                                // engine may deliver no input at all.
            VoiceIOEngine.renderCleanup(hook: hook, data: data, count: count)
            return noErr
        }
    }

    deinit {
        teardown()
        hookBox.deinitialize(count: 1)
        hookBox.deallocate()
    }

    // MARK: - MicCaptureBackend conformance

    /// "Rebuild capture for the given device UID" — for VPIO this means re-pinning (a full
    /// stop/rebuild, VPIO's paired input/output graph doesn't support a cheap re-pin). Returns
    /// `false` when `deviceUID` doesn't resolve to a real HAL device at all, OR when a rebuild was
    /// actually attempted (already running, device changed) and it failed — the caller
    /// (`AudioModel.setupCaptureSession()`) reads this to decide whether `start()` even makes sense.
    @discardableResult
    func configure(deviceUID: String) -> Bool {
        let resolvable = deviceUID == VirtualMicRouting.autoInputSelection
            || Self.haldeviceID(forUID: deviceUID) != nil
        guard resolvable else { return false }
        let changed = deviceUID != desiredInputDeviceUID
        desiredInputDeviceUID = deviceUID
        if changed, wantsRunning {
            return rebuild()
        }
        return true
    }

    /// Starts (or, if already `wantsRunning` but not actually `engine.isRunning` — mid-backoff after
    /// a runtime restart — immediately retries) capture. Review fix M1: the previous `guard
    /// !wantsRunning else { return }` made a second `start()` call while mid-backoff a silent no-op,
    /// which the caller (`AudioModel.startCurrentBackendAndHandleFailure`) then misread as a FRESH
    /// failure (since `isRunning` was still false right after) and fell back prematurely.
    func start() {
        wantsRunning = true
        guard !engine.isRunning else { return }
        restartWorkItem?.cancel()   // supersede any pending scheduled retry with an immediate attempt
        restartWorkItem = nil
        _ = rebuild()
    }

    func stop() {
        wantsRunning = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        teardown()
        hookBox.pointee = nil   // explicit stop ⇒ no more cleanup render (engine isn't running anyway)
        hookOwner = nil
    }

    // MARK: - Hook lifecycle (the ONLY hook-swap path)

    /// Stop → swap the cleanup render hook (safe: the render callback cannot fire while the engine is
    /// stopped, so this needs no lock/atomics) → (re)start if the on-demand gate wants us running.
    /// `owner` is retained strongly for as long as `hook` is wired (review fix C1) — pass the SAME
    /// cleanup engine instance that produced `hook` via `makeRenderHook()`. Returns `false` when
    /// either the gate is closed (hook stored for the next legitimate start) or the rebuild itself
    /// failed.
    @discardableResult
    func restart(withHook hook: CleanupRenderHook?, owner: AnyObject?) -> Bool {
        teardown()
        hookBox.pointee = hook
        hookOwner = hook != nil ? owner : nil
        guard wantsRunning else { return false }
        return buildAndStart()
    }

    /// Detach the current hook (render silence instead) WITHOUT touching `wantsRunning`. This is the
    /// mandatory first step before releasing/stopping a hook-owning cleanup engine (review fix C1) —
    /// `AudioModel.releaseIncomingEngine()`/`releaseSpeakerEngine()` call this before ever writing
    /// `incomingEngine`/`speakerEngine = nil`. Safe regardless of running state: if running, goes
    /// through the same stop→clear→rebuild path as `restart(withHook:owner:)`; if already stopped,
    /// the render callback cannot be firing at all, so writing `hookBox` directly (no rebuild) is
    /// safe and cheaper.
    @discardableResult
    func detachHook() -> Bool {
        guard hookBox.pointee != nil || hookOwner != nil else { return true }   // nothing attached
        if engine.isRunning {
            return restart(withHook: nil, owner: nil)
        }
        hookBox.pointee = nil
        hookOwner = nil
        return true
    }

    // MARK: - Build / teardown

    private func rebuild() -> Bool {
        teardown()
        return buildAndStart()
    }

    /// The graph-build stages that can fail, each mapped to its user-facing `FallbackReason`.
    private enum BuildError: Error {
        case voiceProcessingSetup
        case unsupportedInputRate
        case engineStart
    }

    /// Builds the full VPIO graph and starts the engine, or throws a `BuildError`.
    /// MUST run inside `NNCatchNSException` (see `buildAndStart()`): AVAudioEngine graph calls
    /// (`installTap` / `connect` / `start`) raise Objective-C NSExceptions for conditions that
    /// cannot all be pre-validated — one aborted the whole app in the field on 2026-09-03
    /// (`AUGraphNodeBaseV3::CreateRecordingTap`) despite the bus-rate pre-check below passing.
    private func buildGraphAndStartEngine() throws {
        let inputNode = engine.inputNode   // first access — enable VPIO immediately after, before any
                                            // other graph construction (approved plan, Phase 2 §C).
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw BuildError.voiceProcessingSetup
        }
        // Available since macOS 10.15 (the same OS floor as `setVoiceProcessingEnabled` itself) — no
        // `#available` gate needed (confirmed against the AVFAudio SDK header, see VoiceIOSpike.swift).
        inputNode.isVoiceProcessingAGCEnabled = false

        if #available(macOS 14.0, *) {
            let ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }

        // Output graph: ALWAYS connected, even with no cleanup hook (renders silence) — a record-only
        // VPIO engine may deliver no input buffers at all (docs/knowledge/knowledge1.md 2026-09-02).
        // NO output-device pin (review fix C2 — see class header): output follows the engine's own
        // default output; a change is caught by `installDefaultOutputListener()` → full `rebuild()`.
        if !renderSourceAttached {
            engine.attach(renderSource)
            renderSourceAttached = true
        }
        engine.connect(renderSource, to: engine.mainMixerNode, format: AudioUtils.shared.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: Self.outputConnectionFormat)

        engine.prepare()   // required before `.audioUnit` is non-nil for the pin cycle below.

        // The input bus MUST be genuinely running at 48 kHz before we ever install a fixed-format
        // tap (review fix M4/M5 — restored to the spike-proven fixed mono 48k tap; no resampling).
        // Some BT headsets force VPIO's bus to 16/24 kHz; rather than fight that, give up on VPIO
        // entirely for this device (a headset already has no acoustic loop, so the echo problem this
        // feature targets is structurally absent — `AVCaptureMicBackend` is the correct fallback).
        let busRate = inputNode.outputFormat(forBus: 0).sampleRate
        guard abs(busRate - AudioLatency.sampleRate) < Self.sampleRateToleranceHz else {
            throw BuildError.unsupportedInputRate
        }

        // Input device pin. AUTO selection already matches the system default (VPIO tracks it without
        // any pin), so skip — a pin attempt there would be a pure no-op-or-worse-case-noise risk.
        // Gated on `isManualDeviceSelection` (review fix M4), NOT a `desiredInputDeviceUID ==
        // .autoInputSelection` string comparison: `AudioModel` always passes `configure(deviceUID:)`
        // the RESOLVED concrete UID (never the literal "auto" sentinel), so that comparison would
        // never actually skip anything — `isManualDeviceSelection` is the one signal that correctly
        // distinguishes "auto, resolved to this UID" from "user explicitly picked this UID".
        lastPinFailed = false
        if isManualDeviceSelection,
           let deviceID = Self.haldeviceID(forUID: desiredInputDeviceUID),
           let inputAU = inputNode.audioUnit {
            lastPinFailed = !Self.pinDevice(unit: inputAU, to: deviceID)
        }

        // Fixed mono/48 kHz tap (spike-proven format — `installTap(format: nil)` adopts VPIO's
        // internal multichannel format and fails `engine.start()` with -10875, per knowledge1.md).
        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSizeFrames,
                             format: AudioUtils.shared.processingFormat) { [weak self] buffer, _ in
            // NOT the realtime render thread (see class header) — `self` capture is safe here, same
            // as `AVCaptureMicBackend.captureOutput`.
            guard let self else { return }
            self.normalizer.process(buffer, onAudio: { data, count in
                self.onAudio?(data, count)
            }, onInvalidBuffer: { [weak self] in
                // Review fix M6: never silently drop a malformed buffer — surface it as a runtime
                // failure. Hops to main since this closure runs on the (non-realtime) tap thread and
                // `handleInvalidTapBuffer()` mutates engine state.
                DispatchQueue.main.async { self?.handleInvalidTapBuffer() }
            })
        }

        do {
            try engine.start()
        } catch {
            throw BuildError.engineStart
        }
    }

    /// Builds the full VPIO graph (input VPIO enable → AGC off → ducking relief → ALWAYS-connected
    /// output graph → input device pin → fixed mono 48 kHz tap → `engine.start()`) and installs the
    /// runtime-recovery listeners. MUST be called with the engine already torn down (`teardown()`).
    /// Every failure branch — including an Objective-C NSException raised anywhere inside the
    /// AVAudioEngine graph calls — calls `teardown()`, sets `lastFailureReason`, and returns `false`:
    /// a beta capture backend degrades to the AVCapture fallback, it never takes down the app
    /// (field crash 2026-09-03: an uncaught `CreateRecordingTap` exception killed the process, which
    /// also silenced everything routed through NoNoise Speaker).
    private func buildAndStart() -> Bool {
        var buildError: BuildError?
        let exceptionDescription = NNCatchNSException {
            do {
                try self.buildGraphAndStartEngine()
            } catch let error as BuildError {
                buildError = error
            } catch {
                buildError = .engineStart
            }
        }

        if exceptionDescription != nil || buildError != nil {
            teardown()
            if let exceptionDescription {
                // Main thread (never the render/tap thread) — low-frequency event logging is allowed.
                AudioModel.routeLog.error("VoiceIOEngine build raised NSException, falling back: \(exceptionDescription, privacy: .public)")
            }
            lastFailureReason = (buildError == .unsupportedInputRate) ? .unsupportedInputRate : .startFailed
            return false
        }

        installDefaultOutputListener()
        installConfigChangeObserver()
        consecutiveRestartFailures = 0
        lastFailureReason = nil
        onRebuilt?()
        return true
    }

    /// Main-thread handler for a tap buffer that failed `MicFormatNormalizer`'s validation despite
    /// the fixed-format tap request — treated as fatal for this engine (a malformed format here is a
    /// structural problem, not a transient one worth retrying).
    private func handleInvalidTapBuffer() {
        guard wantsRunning else { return }   // already stopping/stopped — avoid a duplicate notify
        stop()
        onRuntimeFailure?()
    }

    /// Idempotent teardown: remove the tap, remove runtime-recovery listeners, stop + reset the
    /// engine. Safe to call when nothing was built yet (every step is a guarded no-op in that case).
    /// Deliberately does NOT touch `hookBox`/`hookOwner` — callers that need to clear/replace the
    /// hook (`stop()`, `restart(withHook:owner:)`, `detachHook()`) do so explicitly, so an internal
    /// rebuild (`rebuild()`, the runtime-restart path) preserves whatever cleanup hook was already
    /// wired.
    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        removeDefaultOutputListener()
        removeConfigChangeObserver()
        engine.stop()
        engine.reset()
    }

    // MARK: - Device pin helpers

    /// Pins `unit` to `deviceID` via `AudioUnitUninitialize` → `AudioUnitSetProperty
    /// (kAudioOutputUnitProperty_CurrentDevice)` → `AudioUnitInitialize`. REQUIRED once the engine has
    /// been `prepare()`d — a bare `AudioUnitSetProperty` at that point fails with -10849
    /// (`kAudioUnitErr_Initialized`), per docs/knowledge/knowledge1.md's 2026-09-02 [DECISION].
    /// Always re-initializes the unit regardless of whether `Set` succeeded, so the unit is left in a
    /// valid (initialized) state either way for the subsequent `engine.start()`.
    private static func pinDevice(unit: AudioUnit, to deviceID: AudioObjectID) -> Bool {
        guard AudioUnitUninitialize(unit) == noErr else { return false }
        var device = deviceID
        let setStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &device,
                                             UInt32(MemoryLayout<AudioObjectID>.size))
        let initStatus = AudioUnitInitialize(unit)
        return setStatus == noErr && initStatus == noErr
    }

    private static func haldeviceID(forUID uid: String) -> AudioObjectID? {
        var cfUID = uid as CFString
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), ptr, &size, &dev)
        }
        guard status == noErr, dev != 0 else { return nil }
        return dev
    }

    // MARK: - Runtime restart (default-output change / config-change recovery)

    private func installDefaultOutputListener() {
        guard defaultOutputListener == nil else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart()
        }
        defaultOutputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListener else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        defaultOutputListener = nil
    }

    private func installConfigChangeObserver() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleRestart()
        }
    }

    private func removeConfigChangeObserver() {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
    }

    /// Debounces + backs off (0.3s → 1s → 3s, same shape as `AudioModel.scheduleEngineRestart`)
    /// before attempting a full rebuild. VPIO's paired input/output graph doesn't support a cheap
    /// re-pin the way the other engines' single-direction playback does, so every recovery here is a
    /// FULL `rebuild()`. Review fix H6 (knowledge1.md 2026-08-30 [GOTCHA]): bails immediately when
    /// the engine is ALREADY running — macOS can post `.AVAudioEngineConfigurationChange` /
    /// re-deliver the default-output notification for a change that never actually stopped us (or
    /// that a previous restart already fixed); without this guard every such self-induced callback
    /// would count as a "success" and reset the backoff, defeating it.
    private func scheduleRestart() {
        guard wantsRunning, !engine.isRunning else { return }
        restartWorkItem?.cancel()
        let delay = Self.restartDelays[min(consecutiveRestartFailures, Self.restartDelays.count - 1)]
        let item = DispatchWorkItem { [weak self] in self?.attemptRestart() }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func attemptRestart() {
        guard wantsRunning, !engine.isRunning else { return }
        if rebuild() {
            consecutiveRestartFailures = 0
            return
        }
        consecutiveRestartFailures += 1
        switch VoiceIOLogic.startFailureAction(consecutiveFailures: consecutiveRestartFailures) {
        case .retry:
            scheduleRestart()
        case .giveUp:
            wantsRunning = false
            let cb = onRuntimeFailure
            DispatchQueue.main.async { cb?() }
        }
    }
}

// MARK: - Shared cleanup render step

extension VoiceIOEngine {
    /// Drain + latency-trim + (Speaker-only) sustained-silence-bypass decision — EVERYTHING except
    /// the actual DeepFilterNetDSP call. Split out from `renderCleanup` so a test can exercise the
    /// ring/silence-bypass math directly without constructing/running the CoreML model (which loads
    /// asynchronously — unsuitable for a fast host test; DFN itself is never mocked, per the approved
    /// plan, by testing only up to this boundary). Returns `true` iff the caller should still run
    /// `dsp.process` on `data` (i.e. NOT an underflow and NOT a silence bypass). Allocation/lock-free;
    /// fills `data` in place on the underflow path.
    static func prepareCleanupRender(hook: CleanupRenderHook, data: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        let available = Int(tap_ring_available(hook.ringPtr))
        if available > hook.latencyTargetFrames + count {
            tap_ring_drop(hook.ringPtr, UInt32(available - hook.latencyTargetFrames))
        }
        if tap_ring_read(hook.ringPtr, data, UInt32(count)) == 0 {
            data.update(repeating: 0, count: count)   // underflow → silence (allocation-free)
            hook.levelPtr.pointee = 0
            return false
        }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(count))
        hook.levelPtr.pointee = rms

        guard let silenceBox = hook.silenceRunCountBox else { return true }
        if rms < hook.silenceRMSThreshold {
            if silenceBox.pointee < Int32.max { silenceBox.pointee += 1 }
            if silenceBox.pointee > hook.silenceHoldBuffers {
                // Bypass skips dsp.process(), the only place aiActivity updates — decay it here so
                // the popover's AI bar doesn't freeze on a stale value (mirrors SpeakerCleanupEngine's
                // original inline behavior). A plain property write, NOT a CoreML call.
                hook.dsp.takeUnretainedValue().aiActivity *= 0.85
                return false
            }
        } else {
            silenceBox.pointee = 0
        }
        return true
    }

    /// Consolidated cleanup-render step, used by BOTH the `.ownEngine` render closures
    /// (`IncomingCleanupEngine` / `SpeakerCleanupEngine`) and this engine's own `.external` VPIO-hook
    /// path — a byte-for-byte equivalent refactor of the two engines' previously-duplicated render
    /// closures. Allocation/lock/ARC-call-free; fills `data` in place.
    static func renderCleanup(hook: CleanupRenderHook, data: UnsafeMutablePointer<Float>, count: Int) {
        guard prepareCleanupRender(hook: hook, data: data, count: count) else { return }
        hook.dsp.takeUnretainedValue().process(input: data, count: count, output: data)
    }
}
