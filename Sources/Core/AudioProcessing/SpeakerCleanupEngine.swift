import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
import CoreAudio
import Accelerate
import CTapRing

/// Independent "clean incoming audio via the virtual speaker" pipeline. Unlike `IncomingCleanupEngine`
/// (which taps ALL system audio via a Core Audio process tap), this reads from the driver's hidden
/// **"NoNoise Speaker Tap"** input device — the app publishes "NoNoise Speaker" as a selectable
/// output (LINE/Meet/etc. render into it), the driver forwards that audio into its ring2, and the Tap
/// device serves ring2 back out as a normal input. So there is no process tap and no own-process
/// resolution here: the driver already isolated "everything routed to NoNoise Speaker" for us.
///
/// **The Tap is wrapped in a PRIVATE AGGREGATE device (`AudioHardwareCreateAggregateDevice`); the
/// IOProc + `AudioDeviceStart` target the AGGREGATE, never the Tap directly** — mirroring
/// `IncomingCleanupEngine`'s tap+aggregate path. **DO NOT revert to a direct
/// `AudioDeviceCreateIOProcIDWithBlock` on `tapDeviceID`:** driving the IOProc straight off the hidden
/// Tap ties IO-cycle timing to the driver's own zero-timestamp clock, and under real load this caused
/// an IO-overload storm that wedged coreaudiod's IOProc management queue (confirmed via sampling —
/// coreaudiod stuck processing `HALS_OverloadMessage`, all subsequent IOProc create/destroy calls hang
/// forever, system-wide audio IO stops). `IncomingCleanupEngine`'s aggregate-backed path has run
/// stable under the same load — coreaudiod absorbs the IO timing on its side of the aggregate
/// boundary. This engine reads the aggregate, cleans it (its OWN `DeepFilterNetDSP`, DFN only — no
/// `VoiceChain`), and re-renders to the current default PHYSICAL output.
///
/// Deliberately NOT gated `@available(macOS 14.4, *)`: it uses no process-tap API — only the same
/// device-IOProc + private-aggregate mechanism `IncomingCleanupEngine`'s capture side and `AudioModel`'s
/// own capture/playback already use — so it compiles and runs on the package's `.macOS(.v13)` floor.
/// `AudioModel` stores it as a plain `SpeakerCleanupEngine?`.
///
/// Mirrors `IncomingCleanupEngine`'s realtime discipline: the device IOProc (producer, HAL realtime IO
/// thread) and the `AVAudioSourceNode` render block (consumer, audio render thread) are bridged by the
/// lock-free `TapAudioRing` / C `tap_ring` SPSC FIFO — never a locking `RingBuffer`. Both callbacks are
/// allocation/lock/syscall-free and treat the HAL input buffers as read-only.
public final class SpeakerCleanupEngine {

    /// Which playback route this instance was built for — mirrors
    /// `IncomingCleanupEngine.playbackTarget`. `.ownEngine` (default) builds the full playback
    /// `AVAudioEngine` below; `.external` builds ONLY the capture side (Tap+aggregate+IOProc) and
    /// exposes a `CleanupRenderHook` via `makeRenderHook()` for `VoiceIOEngine` to render instead.
    let playbackTarget: CleanupPlaybackTarget

    // MARK: Playback graph (cleaned re-render → default PHYSICAL output) — built only for `.ownEngine`.
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var sourceNodeAttached = false          // attach once; engine.reset() does NOT detach nodes
    private let dsp = DeepFilterNetDSP()             // fresh, independent recurrent state (per instance)

    // MARK: Lock-free producer→consumer bridge (device IOProc → source node), mono 48 kHz.
    private let ring = TapAudioRing(capacityFrames: 48000 * 5)

    // MARK: Hidden Tap input device + the private aggregate wrapping it (the IOProc runs on the
    // AGGREGATE, never the Tap directly — see class header). 0 / nil means "not resolved / not created".
    private var tapDeviceID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    // Pre-allocated mono downmix scratch for the IOProc (never allocate on the realtime thread). The
    // Tap's format is the driver's FIXED canonical ASBD (48 kHz / 2 ch / Float32 interleaved) —
    // confirmed on the raw Tap AND again on the aggregate that wraps it (see `start()`) — so the
    // downmix below is a dedicated stereo-interleaved routine, not the generic
    // N-channel/planar-or-interleaved one `IncomingCleanupEngine` needs for an arbitrary process tap.
    private let monoScratchCapacity = 8192
    private let monoScratch: UnsafeMutablePointer<Float>

    // Perf: sustained near-silence bypasses the CoreML call (the driver's ring2 keeps serving silence
    // to the Tap even with no writer, so this IOProc runs continuously regardless of whether any app
    // is actually routed to "NoNoise Speaker"). Render-thread-only state, boxed on the heap (like
    // `monoScratch`) so the realtime closure captures a raw pointer instead of `self` — zero ARC calls
    // in the render path, matching the project's real-time rule.
    private let silenceRunCountBox: UnsafeMutablePointer<Int32>
    private static let silenceRMSThreshold: Float = 0.0008     // ≈ -62 dBFS
    private static let silenceHoldBuffers: Int32 = 40           // consecutive quiet renders before bypass

    // Lock-free level telemetry for the popover mini meter (see `telemetryLevel` below). Boxed on
    // the heap like `silenceRunCountBox` so the render closure captures a raw pointer instead of
    // `self` — zero ARC calls in the render path, matching the project's real-time rule.
    private let levelBox: UnsafeMutablePointer<Float>

    // Default-output follow.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var configObserver: NSObjectProtocol?
    private var pinnedDeviceID: AudioObjectID = 0
    /// UID of the last output we successfully pinned to that was NOT our own "NoNoise Speaker" —
    /// used as the self-loop fallback (see `repinToDefaultOutput`). Never seeded with the speaker's
    /// own UID.
    private var lastKnownGoodOutputUID: String?
    private var repinning = false

    private var running = false

    /// Invoked on the main queue when the engine tears ITSELF down at runtime AFTER a successful
    /// `start()` — e.g. a default-output re-pin failed (device vanished, or resolved to our own
    /// Speaker with no safe fallback). Mirrors `IncomingCleanupEngine.onRuntimeFailure`.
    public var onRuntimeFailure: (() -> Void)?

    /// True only while the capture side is fully built. Internal (not `private`) so `AudioModel` can
    /// re-verify it after a VoiceIOEngine rebuild (review fix H5), mirroring
    /// `IncomingCleanupEngine.isCaptureAlive`.
    var isCaptureAlive: Bool { tapDeviceID != 0 && aggregateID != 0 && ioProcID != nil }

    /// Default-output listener installed ONLY for `.external` mode — mirrors
    /// `IncomingCleanupEngine.externalHealthListener`. Unlike Incoming's process tap, this engine's
    /// capture side (the driver's Tap + our own private aggregate, created/destroyed end-to-end by
    /// us) is NOT independently invalidated by the system, but the health check is kept symmetric
    /// with Incoming's for the same "cheap, event-driven check" reasoning (review fix H5).
    private var externalHealthListener: AudioObjectPropertyListenerBlock?

    public init(playbackTarget: CleanupPlaybackTarget = .ownEngine) {
        self.playbackTarget = playbackTarget
        monoScratch = UnsafeMutablePointer<Float>.allocate(capacity: monoScratchCapacity)
        monoScratch.initialize(repeating: 0, count: monoScratchCapacity)
        silenceRunCountBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        silenceRunCountBox.pointee = 0
        levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        levelBox.initialize(to: 0)

        // Consumer (render thread, `.ownEngine` only): drain → (maybe bypass) → DFN → play, via the
        // SAME static step `.external` mode's VoiceIOEngine hook uses (`VoiceIOEngine.renderCleanup`)
        // — a byte-for-byte equivalent refactor of what used to be inlined here. Captures only the
        // raw-pointer/Unmanaged `hook` value — no ARC/dispatch calls on `self`.
        let hook = CleanupRenderHook(ringPtr: ring.cRing, dsp: .passUnretained(dsp), levelPtr: levelBox,
                                     latencyTargetFrames: AudioLatency.ringTargetFrames,
                                     silenceRunCountBox: silenceRunCountBox,
                                     silenceRMSThreshold: SpeakerCleanupEngine.silenceRMSThreshold,
                                     silenceHoldBuffers: SpeakerCleanupEngine.silenceHoldBuffers)
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
        silenceRunCountBox.deallocate()
        levelBox.deinitialize(count: 1)
        levelBox.deallocate()
    }

    /// Lock-free telemetry for the popover mini meter — written by the render thread as plain
    /// 32-bit stores (same blessed pattern as `DeepFilterNetDSP.aiActivity`), read from main by
    /// `AudioModel`'s control pump. Last-value store, never read-and-reset.
    public var telemetryLevel: Float { levelBox.pointee }
    public var telemetryActivity: Float { dsp.aiActivity }

    // MARK: - Lifecycle

    /// Resolve + validate the Tap device, wrap it in a private aggregate, wire the IOProc onto the
    /// AGGREGATE, start cleaned playback to a genuine (non-self) default output, then start the
    /// aggregate's IO last. Returns `true` ONLY when the whole pipeline is genuinely live; returns
    /// `false` (fully torn down) on any failure so the owner never retains a half-open engine.
    @discardableResult
    public func start() -> Bool {
        stop()                                  // clean slate; idempotent
        ring.clear()

        guard prepareCaptureInternal() else { stop(); return false }

        if playbackTarget == .ownEngine {
            // Pin + start the playback engine FIRST, refusing a self-loop onto our own "NoNoise
            // Speaker" (see `repinToDefaultOutput`).
            guard startPlayback() else { stop(); return false }
        }

        guard startIO() else { stop(); return false }   // starts the AGGREGATE's IO LAST.

        if playbackTarget == .ownEngine {
            // Follow the default output (manual switches + Bluetooth/TWS auto-switch).
            installDefaultOutputListener()
            installConfigChangeObserver()
        }
        return true
    }

    /// Build ONLY the capture side (Tap + private aggregate + IOProc) — used by the `.external`
    /// (`VoiceIOEngine`-hook) route. Equivalent to `start()`'s capture steps, without touching the
    /// playback graph or starting IO. Returns `true` only when the whole capture chain is built;
    /// `false` (fully torn down) on any failure.
    @discardableResult
    public func prepareCapture() -> Bool {
        stop()
        ring.clear()
        guard prepareCaptureInternal() else { stop(); return false }
        installExternalHealthListener()
        return true
    }

    /// Start the aggregate's IO. Call ONLY after `prepareCapture()` succeeded (`.external`) —
    /// `.ownEngine`'s composite `start()` calls this itself, after its own playback graph is live.
    @discardableResult
    public func startIO() -> Bool {
        guard let proc = ioProcID, aggregateID != 0, AudioDeviceStart(aggregateID, proc) == noErr else {
            return false
        }
        running = true
        return true
    }

    /// Render hook for the `.external` route — `nil` until the capture side is genuinely built.
    /// `VoiceIOEngine.restart(withHook:)` renders this instead of this engine's own (never-built, in
    /// `.external` mode) playback graph.
    func makeRenderHook() -> CleanupRenderHook? {
        guard isCaptureAlive else { return nil }
        return CleanupRenderHook(ringPtr: ring.cRing, dsp: .passUnretained(dsp), levelPtr: levelBox,
                                 latencyTargetFrames: AudioLatency.ringTargetFrames,
                                 silenceRunCountBox: silenceRunCountBox,
                                 silenceRMSThreshold: SpeakerCleanupEngine.silenceRMSThreshold,
                                 silenceHoldBuffers: SpeakerCleanupEngine.silenceHoldBuffers)
    }

    /// Steps 1–6 of the original `start()`: resolve the hidden Tap, confirm its format, wrap it in a
    /// private 48 kHz aggregate, re-confirm the format across the aggregate boundary, and wire the
    /// IOProc. Does NOT call `stop()` on failure — callers (`start()`, `prepareCapture()`) do that,
    /// matching the original call sites exactly.
    private func prepareCaptureInternal() -> Bool {
        // 1. Resolve the hidden "NoNoise Speaker Tap" by UID. 0 ⇒ driver not installed (or doesn't
        //    expose the speaker pair) — the caller (AudioModel) is expected to have already gated on
        //    `SpeakerCleanupEngine.isDriverInstalled()`, but re-check here so `start()` alone is safe.
        let resolved = Self.resolveTapDeviceID()
        guard SpeakerTapLogic.isValidTapDevice(id: resolved) else { return false }
        tapDeviceID = resolved

        // 2. Confirm the canonical format (48 kHz / 2 ch / Float32 interleaved) on the raw Tap.
        //    Feeding a mismatched format into the fixed stereo-interleaved downmix would misread the
        //    buffer, so refuse rather than guess (same "safe side" rule as IncomingCleanupEngine's
        //    48 kHz pin check).
        guard Self.confirmExpectedFormat(deviceID: resolved) else { return false }

        // 3. Wrap the Tap in a PRIVATE AGGREGATE device (mirrors IncomingCleanupEngine's tap+aggregate
        //    construction). The IOProc + AudioDeviceStart below target this aggregate, never the Tap
        //    directly — see the class header for why a direct Tap IOProc is unsafe under load.
        let aggregateUID = "com.ivalsaraj.NoNoiseMac.speaker.aggregate"
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "NoNoise Speaker Cleanup",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: VirtualMicRouting.speakerTapDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [ kAudioSubDeviceUIDKey as String: VirtualMicRouting.speakerTapDeviceUID,
                  kAudioSubDeviceDriftCompensationKey as String: true ]
            ]
        ]
        var newAggID = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &newAggID) == noErr,
              newAggID != 0 else {
            return false
        }
        aggregateID = newAggID

        // 4. Pin the aggregate to 48 kHz (same "refuse rather than guess" rule as
        //    IncomingCleanupEngine.pinSampleRate48k — a rate mismatch across the aggregate boundary
        //    would misfeed the IOProc / DFN).
        guard pinSampleRate48k(newAggID) else { return false }

        // 5. Re-confirm the format the IOProc will ACTUALLY receive once wrapped in the aggregate —
        //    the aggregate boundary can in principle change buffer layout even when the underlying
        //    sub-device didn't, so don't assume the step-2 confirmation on the raw Tap still holds
        //    once IO runs through the aggregate (see IncomingCleanupEngine's tap+aggregate handling).
        guard Self.confirmExpectedFormat(deviceID: newAggID) else { return false }

        // 6. IOProc: downmix the aggregate's stereo-interleaved audio → mono → lock-free ring.
        guard createIOProc(deviceID: newAggID) else { return false }

        return true
    }

    /// Single idempotent teardown — invoked on disable, on `deinit`, AND on every `start()` failure
    /// branch after any HAL object was created. Order: stop IO → destroy IOProc → destroy the private
    /// aggregate → remove listeners → stop engine (mirrors `IncomingCleanupEngine.stop()`). Each handle
    /// is guarded + zeroed, so a second call is a no-op. A leaked aggregate is just a stray private
    /// device (unlike a leaked muted tap, it does not silence other apps), but MUST still be destroyed
    /// on every path to avoid accumulating garbage devices across repeated start/stop cycles.
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
        tapDeviceID = 0
        removeDefaultOutputListener()
        removeConfigChangeObserver()
        removeExternalHealthListener()
        engine.stop()
        engine.reset()
        pinnedDeviceID = 0
        running = false
    }

    // MARK: - Driver availability (checked by the OWNER before constructing an engine)

    /// Whether the driver's hidden "NoNoise Speaker Tap" currently resolves. `AudioModel` calls this
    /// BEFORE constructing an engine so `.unavailable` never requires a live `SpeakerCleanupEngine`
    /// instance (mirrors `IncomingCleanupEngine`'s OS-version gate, but this is a driver-presence
    /// gate instead).
    public static func isDriverInstalled() -> Bool {
        SpeakerTapLogic.isValidTapDevice(id: resolveTapDeviceID())
    }

    // MARK: - Tap device helpers

    private static func resolveTapDeviceID() -> AudioObjectID {
        deviceID(forUID: VirtualMicRouting.speakerTapDeviceUID) ?? AudioObjectID(0)
    }

    /// Read `deviceID`'s INPUT-scope stream format and confirm it matches the driver's canonical
    /// contract via the pure `SpeakerTapLogic.isExpectedFormat`. Called twice in `start()`: once on the
    /// raw Tap (step 2), once on the private aggregate that wraps it (step 5) — the latter is the
    /// format the IOProc actually receives.
    private static func confirmExpectedFormat(deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &asbd) == noErr else { return false }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        return SpeakerTapLogic.isExpectedFormat(sampleRate: asbd.mSampleRate,
                                                channelCount: asbd.mChannelsPerFrame,
                                                isFloat: isFloat, isInterleaved: isInterleaved)
    }

    /// Pin the aggregate's nominal sample rate to 48 kHz and CONFIRM it applied (mirrors
    /// `IncomingCleanupEngine.pinSampleRate48k`): `Set` can return `noErr` yet not take effect, or the
    /// device can refuse the rate. Returns `true` only when a read-back reports 48 kHz, so `start()`
    /// can refuse to feed non-48 kHz frames into DFN. The aggregate isn't running IO yet (started
    /// last), so the read-back is reliable here.
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

    private func createIOProc(deviceID: AudioObjectID) -> Bool {
        let ringPtr = ring.cRing
        let scratch = monoScratch
        let scratchCap = monoScratchCapacity
        var newProc: AudioDeviceIOProcID?
        // `nil` queue ⇒ the block is invoked directly on the HAL realtime IO thread (see header doc).
        // `deviceID` here is the private AGGREGATE wrapping the Tap (see `start()` step 3), never the
        // Tap directly. The aggregate's sole sub-device is input-only, so `inInputData` carries the
        // captured frames; there is no output stream to fill.
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, deviceID, nil) {
            _, inInputData, _, _, _ in
            // inInputData is READ-ONLY (the HAL owns it); we only read frames out of it.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            SpeakerCleanupEngine.downmixStereoInterleavedToRing(abl: abl, scratch: scratch,
                                                                scratchCap: scratchCap, ring: ringPtr)
        }
        guard status == noErr, let proc = newProc else { return false }
        ioProcID = proc
        return true
    }

    /// Allocation/lock-free stereo-interleaved→mono downmix into the lock-free ring. The Tap's format
    /// is confirmed (48 kHz/2ch/Float32 interleaved) before this IOProc is ever installed, so unlike
    /// `IncomingCleanupEngine.downmixToRing` this doesn't need to branch on channel count / layout —
    /// it's always exactly 2 interleaved channels. Reads the HAL buffer read-only; writes only the
    /// ring (via pre-allocated `scratch`). Internal (not `private`) so a test can exercise the
    /// channel-averaging math directly — the tested function IS the runtime function.
    static func downmixStereoInterleavedToRing(abl: UnsafeMutableAudioBufferListPointer,
                                                scratch: UnsafeMutablePointer<Float>, scratchCap: Int,
                                                ring: UnsafeMutablePointer<tap_ring>) {
        guard abl.count > 0, let base = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = Int(abl[0].mDataByteSize) / (2 * MemoryLayout<Float>.size)
        var scale: Float = 0.5
        var off = 0
        while off < frames {
            let n = min(scratchCap, frames - off)
            vDSP_vclr(scratch, 1, vDSP_Length(n))
            let start = base + off * 2
            vDSP_vadd(scratch, 1, start, 2, scratch, 1, vDSP_Length(n))       // + L
            vDSP_vadd(scratch, 1, start + 1, 2, scratch, 1, vDSP_Length(n))   // + R
            vDSP_vsmul(scratch, 1, &scale, scratch, 1, vDSP_Length(n))
            _ = tap_ring_write(ring, scratch, UInt32(n))
            off += n
        }
    }

    // MARK: - Playback (auto-follow default output, refusing a self-loop)

    private func startPlayback() -> Bool {
        engine.stop(); engine.reset()
        guard repinToDefaultOutput() else { return false }
        if !sourceNodeAttached {
            engine.attach(sourceNode)
            sourceNodeAttached = true
        }
        engine.connect(sourceNode, to: engine.mainMixerNode, format: AudioUtils.shared.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do { try engine.start() } catch {
            print("SpeakerCleanupEngine: engine start failed: \(error)")
            return false
        }
        return true
    }

    /// Point the playback output unit at a genuine (non-self) default output. Returns `false` when:
    ///   - there is no default output device at all, OR
    ///   - the default output IS our own "NoNoise Speaker" and no safe fallback (the last known-good
    ///     PHYSICAL output) is available, OR
    ///   - a RUNTIME re-pin to a genuinely different device failed.
    /// **Never pins to our own "NoNoise Speaker"** — that would feed our cleaned re-render straight
    /// back into the Tap device, an unbounded self-loop. `SpeakerTapLogic.repinDecision` is the pure
    /// decision; this function only resolves the two booleans it needs via CoreAudio.
    @discardableResult
    private func repinToDefaultOutput() -> Bool {
        let dev = Self.currentDefaultOutputDevice()
        guard dev != 0 else { return false }

        switch SpeakerTapLogic.repinDecision(hasOutputDevice: true, isSelfLoop: Self.isSelfLoopDevice(dev)) {
        case .rejectNoOutput:
            return false
        case .rejectSelfLoop:
            guard let fallbackUID = lastKnownGoodOutputUID,
                  let fallbackID = Self.deviceID(forUID: fallbackUID),
                  !Self.isSelfLoopDevice(fallbackID) else {
                return false   // no safe fallback → caller must fail rather than loop
            }
            return pin(to: fallbackID)
        case .repin:
            if let uid = Self.deviceUID(for: dev) { lastKnownGoodOutputUID = uid }
            return pin(to: dev)
        }
    }

    /// Cheap no-op re-pin (breaks the set-CurrentDevice → config-change → re-pin feedback cycle), same
    /// shape as `IncomingCleanupEngine.repinToDefaultOutput`'s `AudioUnitSetProperty` call.
    private func pin(to dev: AudioObjectID) -> Bool {
        guard dev != pinnedDeviceID else { return true }
        guard let au = engine.outputNode.audioUnit else { return true } // unrealized unit follows default
        var d = dev
        if AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                &d, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr {
            pinnedDeviceID = dev
            return true
        }
        return pinnedDeviceID == 0
    }

    /// Re-pin on default-output / config change. This only touches the PLAYBACK (output) side; the
    /// capture side (Tap + our private aggregate wrapping it) is unaffected by default-OUTPUT changes
    /// and isn't rebuilt here — the aggregate is a private device we own end-to-end (created in
    /// `start()`, destroyed only in `stop()`), unlike `IncomingCleanupEngine`'s process tap, which the
    /// system can independently invalidate and therefore needs a tap-alive-vs-dead rebuild branch. Any
    /// failure (no output, or self-loop with no fallback) MUST tear down and notify the owner so the UI
    /// drops from `.cleaning` to `.failed` instead of lying.
    private func repinPlayback() {
        guard running, !repinning else { return }
        repinning = true
        defer { repinning = false }
        engine.stop()
        guard repinToDefaultOutput() else {
            teardownAndNotifyFailure()
            return
        }
        do {
            try engine.start()
        } catch {
            print("SpeakerCleanupEngine: re-pin engine start failed: \(error)")
            teardownAndNotifyFailure()
        }
    }

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

    // MARK: - Device resolution helpers (non-realtime; called only from main-thread lifecycle code)

    private static func currentDefaultOutputDevice() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
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

    private static func deviceUID(for id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    private static func deviceName(for id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    /// True when `id` resolves to our OWN "NoNoise Speaker" (by UID or name — same defensive
    /// double-match as `VirtualMicRouting.isNoNoiseSpeaker`, reused here directly).
    private static func isSelfLoopDevice(_ id: AudioObjectID) -> Bool {
        guard let uid = deviceUID(for: id) else { return false }
        let name = deviceName(for: id) ?? ""
        let info = VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: false, hasOutput: true)
        return VirtualMicRouting.isNoNoiseSpeaker(info)
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

    /// `.external`-mode-only health check, mirroring `IncomingCleanupEngine.checkExternalHealth`.
    /// Reuses `IncomingTapLogic.repinDecision` (a plain `tapAlive -> .repin/.rebuild` mapping, not
    /// specific to the process-tap path) rather than re-deriving the same trivial decision.
    private func checkExternalHealth() {
        guard playbackTarget == .external, running else { return }
        guard IncomingTapLogic.repinDecision(tapAlive: isCaptureAlive) == .repin else {
            AudioModel.routeLog.info("cleanup.health engine=speaker verdict=teardown")
            teardownAndNotifyFailure()
            return
        }
    }
}
