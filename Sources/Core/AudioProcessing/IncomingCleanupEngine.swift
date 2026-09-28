import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
import CoreAudio
import Accelerate
import CTapRing

/// Independent "clean the OTHER side" pipeline. Captures **all system audio except NoNoise's own
/// process** via a Core Audio **process tap** (no virtual device, no BlackHole), runs it through its
/// OWN DeepFilterNet engine (DFN only — no `VoiceChain`), and re-renders the cleaned result to the
/// **current default output**, auto-following device changes. The tapped originals are **muted**, so
/// the user hears only NoNoise's cleaned playback.
///
/// Deliberately NOT an `AudioModel`: it never touches the mic path or the NoNoise Mic sink. The
/// second CoreML stream has real ANE + allocation/model-load cost, so the OWNER (`AudioModel`)
/// constructs this only while enabled and releases it to nil on disable (zero cost when off). A
/// fresh instance ⇒ fresh DFN recurrent state.
///
/// macOS **14.4+** only (tap APIs); the whole type is gated so the package still builds against its
/// `.macOS(.v13)` deployment target. The tap IOProc (producer) and the `AVAudioSourceNode` render
/// (consumer) are BOTH realtime threads, bridged by a lock-free `TapAudioRing` (never a locking
/// `RingBuffer`). Both callbacks are allocation/lock/syscall-free and treat the HAL input as read-only.
@available(macOS 14.4, *)
public final class IncomingCleanupEngine {

    /// Which playback route this instance was built for. `.ownEngine` (the default) builds the full
    /// `AVAudioEngine` playback graph below, exactly as before Phase 2. `.external` skips it entirely
    /// — the capture side (tap+aggregate+IOProc) is built via `prepareCapture()`/`startIO()`, and
    /// `makeRenderHook()` exposes a `CleanupRenderHook` for `VoiceIOEngine` to render instead. Not
    /// mutable after construction — a route change tears this instance down and builds a fresh one
    /// (see `AudioModel.applyCleanupPlaybackRoute`).
    let playbackTarget: CleanupPlaybackTarget

    // MARK: Playback graph (cleaned re-render → default output) — built only for `.ownEngine`.
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var sourceNodeAttached = false          // attach once; engine.reset() does NOT detach nodes
    private let dsp = DeepFilterNetDSP()             // fresh, independent recurrent state (per instance)

    // MARK: Lock-free producer→consumer bridge (tap IOProc → source node), mono 48 kHz.
    private let ring = TapAudioRing(capacityFrames: 48000 * 5)

    // MARK: Tap / aggregate (the capture side). 0 / nil means "not created".
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    // Tap stream layout, read ONCE at setup (non-realtime) from kAudioTapPropertyFormat. The IOProc
    // uses these stored values + the buffer's mDataByteSize — it never reads HAL properties itself.
    private var tapChannels: Int = 2
    private var tapIsInterleaved: Bool = true

    // Pre-allocated mono downmix scratch for the IOProc (never allocate on the realtime thread).
    private let monoScratchCapacity = 8192
    private let monoScratch: UnsafeMutablePointer<Float>

    // Lock-free level telemetry for the popover mini meter (see `telemetryLevel` below). Boxed on
    // the heap like `monoScratch` so the render closure captures a raw pointer instead of `self` —
    // zero ARC calls in the render path, matching the project's real-time rule.
    private let levelBox: UnsafeMutablePointer<Float>

    // Default-output follow.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var configObserver: NSObjectProtocol?
    private var pinnedDeviceID: AudioObjectID = 0
    private var repinning = false

    private var running = false

    /// Invoked on the main queue when the engine tears ITSELF down at runtime AFTER a successful
    /// `start()` — e.g. a default-output re-pin/rebuild that failed, or the output device vanished.
    /// The owner (`AudioModel`) releases the engine to `nil` and surfaces `.failed`, so the UI never
    /// shows a lying `.cleaning` over a dead pipeline. NOT called for caller-initiated `stop()`
    /// (disable / `deinit`) or for `start()`-time failures (the caller already observes the `Bool`).
    public var onRuntimeFailure: (() -> Void)?

    /// True only while the capture side is fully built. Used by the re-pin-vs-rebuild decision
    /// (`.ownEngine`) AND by the `.external` health check (`checkExternalHealth`) — internal (not
    /// `private`) so `AudioModel` can re-verify it after a VoiceIOEngine rebuild (review fix H5).
    var isCaptureAlive: Bool { tapID != 0 && aggregateID != 0 && ioProcID != nil }

    /// Default-output listener installed ONLY for `.external` mode (`.ownEngine` uses
    /// `defaultOutputListener`/`repinPlayback` instead). A default-output change doesn't directly
    /// affect this engine's OWN (nonexistent, in `.external` mode) playback, but hardware churn that
    /// flips the default output can also be the same event that kills the tap/aggregate — this is a
    /// minimal health check, not a repin (review fix H5).
    private var externalHealthListener: AudioObjectPropertyListenerBlock?

    public init(playbackTarget: CleanupPlaybackTarget = .ownEngine) {
        self.playbackTarget = playbackTarget
        monoScratch = UnsafeMutablePointer<Float>.allocate(capacity: monoScratchCapacity)
        monoScratch.initialize(repeating: 0, count: monoScratchCapacity)
        levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        levelBox.initialize(to: 0)

        // Consumer (render thread, `.ownEngine` only): drain → DFN → play, via the SAME static step
        // `.external` mode's VoiceIOEngine hook uses (`VoiceIOEngine.renderCleanup`) — a byte-for-byte
        // equivalent refactor of what used to be inlined here. Captures only the raw-pointer/Unmanaged
        // `hook` value, so the render path makes no ARC/dispatch calls on `self`.
        let hook = CleanupRenderHook(ringPtr: ring.cRing, dsp: .passUnretained(dsp), levelPtr: levelBox,
                                     latencyTargetFrames: AudioLatency.ringTargetFrames)
        sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            VoiceIOEngine.renderCleanup(hook: hook, data: data, count: Int(frameCount))
            return noErr
        }
    }

    deinit {
        stop()
        monoScratch.deinitialize(count: monoScratchCapacity)
        monoScratch.deallocate()
        levelBox.deinitialize(count: 1)
        levelBox.deallocate()
    }

    /// Lock-free telemetry for the popover mini meter — written by the render thread as plain
    /// 32-bit stores (same blessed pattern as `DeepFilterNetDSP.aiActivity`), read from main by
    /// `AudioModel`'s control pump. Last-value store, never read-and-reset.
    public var telemetryLevel: Float { levelBox.pointee }
    public var telemetryActivity: Float { dsp.aiActivity }

    // MARK: - Lifecycle

    /// Build the tap + aggregate + IOProc, start cleaned playback to the default output, then start
    /// the tap IO last. Returns `true` ONLY when the whole pipeline is genuinely live; returns
    /// `false` (fully torn down) on any failure so the owner never retains a half-open engine.
    @discardableResult
    public func start() -> Bool {
        stop()                                  // clean slate; idempotent
        ring.clear()

        guard prepareCaptureInternal() else { stop(); return false }

        if playbackTarget == .ownEngine {
            // Pin + start the playback engine FIRST, so the global mute (started by `startIO()`
            // below) is only active once our cleaned re-render is already playing.
            guard startPlayback() else { stop(); return false }
        }

        guard startIO() else { stop(); return false }   // starts the aggregate IO LAST.

        if playbackTarget == .ownEngine {
            // Follow the default output (manual switches + Bluetooth/TWS auto-switch).
            installDefaultOutputListener()
            installConfigChangeObserver()
        }
        return true
    }

    /// Build ONLY the capture side (tap + aggregate + IOProc) — used by the `.external`
    /// (`VoiceIOEngine`-hook) route, where playback happens through `VoiceIOEngine`'s own output bus
    /// instead of this engine's `AVAudioEngine`. Equivalent to `start()`'s capture steps, without
    /// touching the playback graph or starting IO. Returns `true` only when the whole capture chain
    /// is built; `false` (fully torn down) on any failure.
    @discardableResult
    public func prepareCapture() -> Bool {
        stop()
        ring.clear()
        guard prepareCaptureInternal() else { stop(); return false }
        installExternalHealthListener()
        return true
    }

    /// Start the aggregate's IO (the global mute engages here, per `tapautostart=true`). Call ONLY
    /// after `prepareCapture()` succeeded (`.external`) — `.ownEngine`'s composite `start()` calls
    /// this itself, after its own playback graph is already live.
    @discardableResult
    public func startIO() -> Bool {
        guard let proc = ioProcID, aggregateID != 0, AudioDeviceStart(aggregateID, proc) == noErr else {
            return false
        }
        running = true
        return true
    }

    /// Render hook for the `.external` route — `nil` until the capture side is genuinely built
    /// (`tapAlive`). `VoiceIOEngine.restart(withHook:)` renders this instead of this engine's own
    /// (never-built, in `.external` mode) playback graph.
    func makeRenderHook() -> CleanupRenderHook? {
        guard isCaptureAlive else { return nil }
        return CleanupRenderHook(ringPtr: ring.cRing, dsp: .passUnretained(dsp), levelPtr: levelBox,
                                 latencyTargetFrames: AudioLatency.ringTargetFrames)
    }

    /// Steps 1–5 of the original `start()`: resolve our own process object, build the muted global-
    /// exclude tap, wrap it in a private 48 kHz aggregate, read the tap's stream layout, and wire the
    /// IOProc. Does NOT call `stop()` on failure — callers (`start()`, `prepareCapture()`) do that,
    /// matching the original call sites exactly.
    private func prepareCaptureInternal() -> Bool {
        // 1. Resolve our own audio process object. HARD-FAIL on invalid resolution: a global-exclude
        //    tap around an unknown own-process id would exclude nothing and re-capture/mute our own
        //    cleaned playback (feedback / self-mute).
        var pid = ProcessInfo.processInfo.processIdentifier      // pid_t (Int32)
        var ourProcessObject = AudioObjectID(0)
        var translateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var idSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let translateStatus = withUnsafeMutablePointer(to: &pid) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translateAddr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr, &idSize, &ourProcessObject)
        }
        guard IncomingTapLogic.isValidProcessObject(status: translateStatus, id: ourProcessObject) else {
            return false
        }

        // 2. Muted global-exclude tap (everything EXCEPT us; originals muted).
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ourProcessObject])
        desc.name = "NoNoise Clean Incoming"
        desc.muteBehavior = .muted
        desc.isPrivate = true
        var newTapID = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(desc, &newTapID) == noErr, newTapID != 0 else {
            return false
        }
        tapID = newTapID

        // 3. Private aggregate including the tap; pinned to 48 kHz so the IOProc gets 48 kHz frames
        //    (no AVAudioConverter on the realtime thread). tapautostart=true ⇒ the tap starts when
        //    we call AudioDeviceStart (`startIO()`), so the mute begins only then.
        let aggregateUID = "com.ivalsaraj.NoNoiseMac.incoming.aggregate"
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "NoNoise Clean Incoming",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [ kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                  kAudioSubTapDriftCompensationKey as String: true ]
            ]
        ]
        var newAggID = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &newAggID) == noErr,
              newAggID != 0 else {
            return false
        }
        aggregateID = newAggID
        // DFN expects 48 kHz. If the aggregate refuses the rate, feeding the IOProc's wrong-rate
        // frames into DFN would detune/garble the cleaned audio, so fail cleanly rather than
        // silently mis-process. (A non-realtime SRC fallback is the deferred enhancement; see spec §1.)
        guard pinSampleRate48k(newAggID) else { return false }

        // 4. Read the tap stream layout ONCE (non-realtime). Fail if the format is unusable.
        guard readTapLayout(tapID: newTapID) else { return false }

        // 5. IOProc: downmix tapped audio → mono → lock-free ring. Allocation/lock-free; reads the
        //    HAL input buffers read-only.
        guard createIOProc(aggregateID: newAggID) else { return false }

        return true
    }

    /// Single idempotent teardown — invoked on disable, on `deinit`, AND on every `start()` failure
    /// branch after any HAL object was created. A leaked **muted** tap keeps OTHER apps muted
    /// system-wide, so this MUST run on all paths. Each handle is guarded + zeroed, so a second call
    /// is a no-op. Order matches the spec (stop IO → destroy IOProc → destroy aggregate → destroy
    /// tap → remove listeners → stop engine).
    public func stop() {
        if let proc = ioProcID {
            if aggregateID != 0 {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        removeDefaultOutputListener()
        removeConfigChangeObserver()
        removeExternalHealthListener()
        engine.stop()
        engine.reset()
        pinnedDeviceID = 0
        running = false
    }

    // MARK: - Tap / aggregate helpers

    /// Pin the device's nominal sample rate to 48 kHz and CONFIRM it applied: `Set` can return
    /// `noErr` yet not take effect (or the device can refuse the rate). Returns `true` only when a
    /// read-back reports 48 kHz, so `start()` can refuse to feed non-48 kHz frames into DFN. The
    /// device isn't running IO yet (started last), so the read-back is reliable here.
    private func pinSampleRate48k(_ device: AudioObjectID) -> Bool {
        var sr: Float64 = 48000
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectSetPropertyData(device, &addr, 0, nil,
                                         UInt32(MemoryLayout<Float64>.size), &sr) == noErr else {
            return false
        }
        var actual: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &actual) == noErr else {
            return false
        }
        return abs(actual - 48000) < 1.0
    }

    /// Read the tap's `AudioStreamBasicDescription` once. Returns false if unreadable / zero channels.
    private func readTapLayout(tapID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr,
              asbd.mChannelsPerFrame > 0 else { return false }
        tapChannels = Int(asbd.mChannelsPerFrame)
        tapIsInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        return true
    }

    private func createIOProc(aggregateID: AudioObjectID) -> Bool {
        let ringPtr = ring.cRing
        let scratch = monoScratch
        let scratchCap = monoScratchCapacity
        let channels = tapChannels
        let interleaved = tapIsInterleaved
        var newProc: AudioDeviceIOProcID?
        // `nil` queue ⇒ the block is invoked directly on the HAL realtime IO thread (see header doc).
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) {
            _, inInputData, _, _, _ in
            // inInputData is READ-ONLY (the HAL owns it); we only read frames out of it.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            IncomingCleanupEngine.downmixToRing(abl: abl, channels: channels, interleaved: interleaved,
                                                scratch: scratch, scratchCap: scratchCap, ring: ringPtr)
        }
        guard status == noErr, let proc = newProc else { return false }
        ioProcID = proc
        return true
    }

    /// Allocation/lock-free stereo(or N)→mono downmix written into the lock-free ring. Reads the
    /// HAL-provided buffers read-only; writes only the ring (via pre-allocated `scratch`). Static +
    /// pointer-only so the realtime block makes no ARC/Swift-runtime calls. Internal (not `private`)
    /// so `IncomingDownmixTests` can exercise the channel-averaging math (mono / interleaved / planar)
    /// directly — the tested function IS the runtime function.
    static func downmixToRing(abl: UnsafeMutableAudioBufferListPointer,
                                      channels: Int, interleaved: Bool,
                                      scratch: UnsafeMutablePointer<Float>, scratchCap: Int,
                                      ring: UnsafeMutablePointer<tap_ring>) {
        guard abl.count > 0, channels > 0 else { return }
        if channels == 1 {
            guard let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            var off = 0
            while off < frames {
                let n = min(scratchCap, frames - off)
                _ = tap_ring_write(ring, p + off, UInt32(n))
                off += n
            }
            return
        }
        var scale = 1.0 / Float(channels)
        if interleaved {
            guard let base = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(abl[0].mDataByteSize) / (channels * MemoryLayout<Float>.size)
            var off = 0
            while off < frames {
                let n = min(scratchCap, frames - off)
                vDSP_vclr(scratch, 1, vDSP_Length(n))
                let start = base + off * channels
                for ch in 0..<channels {
                    vDSP_vadd(scratch, 1, start + ch, channels, scratch, 1, vDSP_Length(n))
                }
                vDSP_vsmul(scratch, 1, &scale, scratch, 1, vDSP_Length(n))
                _ = tap_ring_write(ring, scratch, UInt32(n))
                off += n
            }
        } else {
            let bufCount = abl.count
            guard bufCount > 0 else { return }
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            var off = 0
            while off < frames {
                let n = min(scratchCap, frames - off)
                vDSP_vclr(scratch, 1, vDSP_Length(n))
                for ch in 0..<channels where ch < bufCount {
                    guard let cptr = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    vDSP_vadd(scratch, 1, cptr + off, 1, scratch, 1, vDSP_Length(n))
                }
                vDSP_vsmul(scratch, 1, &scale, scratch, 1, vDSP_Length(n))
                _ = tap_ring_write(ring, scratch, UInt32(n))
                off += n
            }
        }
    }

    // MARK: - Playback (auto-follow default output)

    private func startPlayback() -> Bool {
        engine.stop(); engine.reset()
        // Refuse to start without a usable output device: starting the muted tap (step 7) with no
        // place to play the cleaned audio would silence every OTHER app system-wide. A valid default
        // (even if the explicit pin can't apply yet) is enough — the engine then plays to that default.
        guard repinToDefaultOutput() else { return false }
        if !sourceNodeAttached {
            engine.attach(sourceNode)
            sourceNodeAttached = true
        }
        engine.connect(sourceNode, to: engine.mainMixerNode, format: AudioUtils.shared.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do { try engine.start() } catch {
            print("IncomingCleanupEngine: engine start failed: \(error)")
            return false
        }
        return true
    }

    /// Point the playback output unit at the current default output. Returns `false` when we end up
    /// unable to play to the current default:
    ///   - no default output device at all (`dev == 0`), OR
    ///   - a RUNTIME re-pin to a genuinely different device failed (`pinnedDeviceID != 0` and
    ///     `AudioUnitSetProperty` failed) — the engine would otherwise stay stuck on the OLD device and
    ///     silently stop following the default; the caller tears down + notifies instead.
    /// Returns `true` for the benign cases: already pinned (cheap no-op); the output unit isn't realized
    /// yet (an unrealized unit isn't pinned to anything, so it follows the live default on start); and a
    /// `Set` failure on FIRST start (`pinnedDeviceID == 0`), where AVAudioEngine still renders to its own
    /// default (= the current default). The early no-op also breaks the set-CurrentDevice →
    /// config-change → re-pin feedback cycle.
    @discardableResult
    private func repinToDefaultOutput() -> Bool {
        let dev = Self.currentDefaultOutputDevice()
        guard dev != 0 else { return false }            // no output device at all → caller must not start
        guard dev != pinnedDeviceID else { return true } // already pinned (cheap no-op)
        guard let au = engine.outputNode.audioUnit else { return true } // unrealized unit isn't pinned → follows default
        var d = dev
        if AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                &d, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr {
            pinnedDeviceID = dev
            return true
        }
        // Set failed. First start (pinnedDeviceID == 0) still plays to the engine's default; a runtime
        // switch (pinnedDeviceID != 0) would be stuck on the OLD device → fail so the caller tears down.
        return pinnedDeviceID == 0
    }

    /// Re-pin (cheap) on default-output / config change, UNLESS the tap itself died (full rebuild).
    /// Any failure here MUST tear down (never leave a muted tap silencing other apps) and notify the
    /// owner so the UI drops from `.cleaning` to `.failed` instead of lying.
    private func repinPlayback() {
        guard running, !repinning else { return }
        repinning = true
        defer { repinning = false }
        switch IncomingTapLogic.repinDecision(tapAlive: isCaptureAlive) {
        case .repin:
            engine.stop()
            guard repinToDefaultOutput() else {        // device vanished, or re-pin to the new default failed
                teardownAndNotifyFailure(); return     // → don't keep a muted tap stuck on the wrong/no output
            }
            do {
                try engine.start()
            } catch {
                print("IncomingCleanupEngine: re-pin engine start failed: \(error)")
                teardownAndNotifyFailure()
            }
        case .rebuild:
            stop()
            if !start() { notifyRuntimeFailure() }     // start() already tore itself down on false
        }
    }

    /// Full teardown + owner notification for a runtime failure (re-pin path). `stop()` is idempotent.
    private func teardownAndNotifyFailure() {
        stop()
        notifyRuntimeFailure()
    }

    /// Hop the owner callback to main asynchronously, capturing only a copy of the closure (never
    /// `self`), so the owner can safely release this engine without deallocating it mid-call.
    private func notifyRuntimeFailure() {
        let cb = onRuntimeFailure
        DispatchQueue.main.async { cb?() }
    }

    private static func currentDefaultOutputDevice() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private func installDefaultOutputListener() {
        guard defaultOutputListener == nil else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.repinPlayback()                       // delivered on .main (queue below)
        }
        defaultOutputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            DispatchQueue.main, block)
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListener else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                               DispatchQueue.main, block)
        defaultOutputListener = nil
    }

    private func installConfigChangeObserver() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.repinPlayback()
        }
    }

    private func removeConfigChangeObserver() {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
    }

    // MARK: - `.external`-mode health check (review fix H5)

    private func installExternalHealthListener() {
        guard externalHealthListener == nil else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkExternalHealth()
        }
        externalHealthListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            DispatchQueue.main, block)
    }

    private func removeExternalHealthListener() {
        guard let block = externalHealthListener else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                               DispatchQueue.main, block)
        externalHealthListener = nil
    }

    /// `.external`-mode-only: a default-output flip is used as a cheap trigger to re-check whether
    /// the SAME underlying hardware event also killed our tap/aggregate (this engine has no playback
    /// graph of its own to repin in this mode). Reuses `IncomingTapLogic.repinDecision` — a `.rebuild`
    /// verdict here means the capture side died, so tear down and notify the owner exactly like the
    /// `.ownEngine` `repinPlayback()`'s own `.rebuild` branch does.
    private func checkExternalHealth() {
        guard playbackTarget == .external, running else { return }
        guard IncomingTapLogic.repinDecision(tapAlive: isCaptureAlive) == .repin else {
            AudioModel.routeLog.info("cleanup.health engine=incoming verdict=teardown")
            teardownAndNotifyFailure()
            return
        }
    }
}
