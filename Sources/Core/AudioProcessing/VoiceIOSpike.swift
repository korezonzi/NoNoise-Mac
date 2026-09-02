import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
import CoreAudio
import Accelerate

/// Feasibility harness behind the hidden `--aec-spike <scenario>` CLI mode.
///
/// Context: the built-in-speaker echo problem (mic re-hears its own AI-cleaned output through the
/// speaker) has a candidate root fix — moving mic capture onto Apple **Voice Processing I/O**
/// (`AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`), which does its own echo
/// cancellation against whatever this process plays out its own output node. Before committing to
/// that redesign, this harness measures whether VPIO actually behaves the way that plan assumes:
/// does it cancel our own loopback echo, does it leave CROSS-process echo (e.g. another app's
/// audio) uncancelled, what format does it force capture into, can it be pinned to a manual input
/// device, how does AGC interact with our own levelling, and can it coexist with the existing
/// `IncomingCleanupEngine` tap.
///
/// This is a dev-only diagnostic mode, not a shipped feature — it is deliberately hidden behind
/// `--aec-spike` rather than exposed as a first-class CLI mode (see AGENTS.md's "CLI offline file
/// mode" section). It still follows the project's audio-engine discipline where it matters:
/// truthful start/stop (never leak a HAL device or a running `AVAudioEngine`, always via `defer`
/// so a mid-scenario throw can't skip cleanup), and no Swift array append/allocation/ARC-object
/// assignment inside a real-time tap/render callback (see `SpikeRecorder` / `SpikePlaybackSource`
/// below, mirroring `IncomingCleanupEngine`'s and `SpeakerCleanupEngine`'s pre-allocated-scratch
/// pattern).
public final class VoiceIOSpikeRunner {

    public init() {}

    // MARK: - Tunable constants (named, not magic numbers)

    /// Burst playback period: 2.0s @ 48 kHz (1.0s ON, 1.0s OFF).
    static let burstPeriodFrames = 96_000
    /// ON portion of each burst period: 1.0s @ 48 kHz.
    static let burstOnFrames = 48_000
    /// Linear fade at each ON/OFF boundary, to avoid a click that would itself correlate falsely.
    static let burstFadeMs: Double = 10
    /// Burst amplitude (linear, below clipping — this is a measurement signal, not content).
    /// 0.7 rather than 0.25: the self-echo ERLE measurement is floor-limited by room noise
    /// (measured ~-46 dBFS ambient); the baseline echo must sit well above that floor for a
    /// >= 20 dB ERLE to be measurable at all.
    static let burstAmplitude: Float = 0.7
    /// Frames skipped at the start of every recording before ON/OFF analysis, to let DFN/VPIO's
    /// adaptive filters converge past their startup transient (3.0s @ 48 kHz).
    static let convergenceSkipFrames = 144_000
    /// Max lag searched by the self-echo correlation (1.0s @ 48 kHz — generous for a loopback path).
    static let correlationMaxLagFrames48k = 48_000
    /// Windowed-RMS window used for the AGC variance comparison (100 ms @ 48 kHz).
    static let agcWindowFrames = 4_800
    /// Fixed recording length for the AGC scenario (spec: 30s of steady speech per pass).
    static let agcRecordingDurationSec: Double = 30
    /// Tap-scenario telemetry sampling: 10 samples, 0.5s apart (5s total).
    static let tapTelemetrySampleCount = 10
    static let tapTelemetrySampleIntervalSec: Double = 0.5
    /// `installTap` buffer size used by every recording pass (100 ms @ 48 kHz).
    static let tapBufferSizeFrames: AVAudioFrameCount = 4_800
    /// Frames-per-second safety margin assumed when sizing a `SpikeRecorder`'s fixed capacity —
    /// double the nominal 48 kHz, since VPIO (or an unusual input device) can force a higher
    /// native capture rate than NoNoise's own 48 kHz standard.
    static let recorderCapacitySafetySampleRate = 96_000
    /// Fixed capture length for the `pin` scenario's semantic-success check.
    static let pinRecordingDurationSec: Double = 2
    /// How long the `format` scenario waits for the first tap buffer before giving up.
    static let formatTapWaitTimeoutSec: Double = 5
    /// Chunk size used when replaying a recorded buffer through `DeepFilterNetDSP` offline
    /// (100 ms @ 48 kHz — matches `tapBufferSizeFrames`'s cadence, chosen independently since it's
    /// a DSP processing chunk rather than a tap buffer size).
    static let dfnOfflineChunkFrames = 4_800
    /// Headroom added to a resampled buffer's capacity, since the exact output frame count of an
    /// `AVAudioConverter` pass can round up slightly beyond the naive ratio estimate.
    static let resampleCapacityPaddingFrames: AVAudioFrameCount = 16
    /// Below this OFF-pass correlation peak, the self-echo scenario's ERLE/verdict is flagged as
    /// unreliable — the burst likely wasn't captured cleanly in the first place (wrong device? no
    /// speaker output? mic muted?), so a low ERLE would just reflect a bad capture, not real AEC.
    static let selfEchoOffCorrelationWarningThreshold: Float = 0.1

    /// `self`/`perf` need at least this much recording to skip the convergence window AND still
    /// see two full burst periods for a meaningful ON/OFF RMS comparison. A shorter
    /// `--spike-duration` would silently degrade into a `verdict: .fail` (or all-zero RMS) that
    /// LOOKS like a real measurement but is actually just "there wasn't enough audio to measure" —
    /// reject it explicitly instead.
    static var minAnalyzableDurationSec: Double {
        Double(convergenceSkipFrames + 2 * burstPeriodFrames) / 48_000.0
    }

    private enum SpikeError: Error, CustomStringConvertible {
        case voiceProcessingSetupFailed(String)
        case engineStartFailed(String)
        case unavailable(String)
        case inputDeviceNotFound(String)
        case inputDevicePinFailed(String, OSStatus)

        var description: String {
            switch self {
            case .voiceProcessingSetupFailed(let detail): return "Voice Processing I/O setup failed: \(detail)"
            case .engineStartFailed(let detail): return "AVAudioEngine failed to start: \(detail)"
            case .unavailable(let detail): return detail
            case .inputDeviceNotFound(let query): return "No input device matched '--spike-input \(query)'."
            case .inputDevicePinFailed(let name, let status):
                return "Could not pin input device '\(name)' (OSStatus \(status))."
            }
        }
    }

    /// Runs the requested scenario(s). Returns the HARNESS exit code — NOT a summary of every
    /// scenario's own verdict:
    ///   - `0`: every requested scenario ran to completion with no internal error (a `.fail`
    ///     `SpikeVerdict` inside an otherwise-completed scenario does NOT affect this).
    ///   - `2`: the harness itself worked, but at least one scenario threw before finishing and
    ///     was recorded under `results.errors`.
    ///   - `1`: the harness could not even start (e.g. `--spike-out` could not be created, or an
    ///     invalid `AECSpikeOptions.scenario` reached here bypassing `CLIArguments.parse`).
    public func run(_ options: AECSpikeOptions) async -> Int32 {
        if !FileManager.default.fileExists(atPath: options.outputDir) {
            do {
                try FileManager.default.createDirectory(atPath: options.outputDir, withIntermediateDirectories: true)
            } catch {
                print("Error: could not create --spike-out directory '\(options.outputDir)': \(error)")
                return 1
            }
        }

        guard let requestedScenario = AECSpikeScenario(rawValue: options.scenario) else {
            // CLIArguments.parse() already validates this — reaching here means an AECSpikeOptions
            // was constructed directly (e.g. by a future caller) with a bad raw scenario string.
            print("Error: unknown scenario '\(options.scenario)'.")
            return 1
        }

        var results = SpikeResultsJSON(scenario: options.scenario,
                                       generatedAt: ISO8601DateFormatter().string(from: Date()),
                                       durationSec: options.durationSec)

        let scenarios: [AECSpikeScenario] = requestedScenario == .all
            ? AECSpikeScenario.allCases.filter { $0 != .all }
            : [requestedScenario]

        for scenario in scenarios {
            print("\n=== AEC Spike: \(scenario.rawValue) ===")
            do {
                try await runOne(scenario, options: options, into: &results)
            } catch {
                let message = String(describing: error)
                print("Scenario '\(scenario.rawValue)' failed: \(message)")
                results.errors[scenario.rawValue] = message
            }
        }

        writeResults(results, to: options.outputDir)
        return results.errors.isEmpty ? 0 : 2
    }

    /// Exhaustive, `default`-free dispatch — the compiler enforces that every `AECSpikeScenario`
    /// case (including any added later) is handled. `.all` is unreachable in practice (`run(_:)`
    /// expands it to the other seven cases before ever calling this), but must still be listed for
    /// the switch to be exhaustive.
    private func runOne(_ scenario: AECSpikeScenario, options: AECSpikeOptions,
                        into results: inout SpikeResultsJSON) async throws {
        switch scenario {
        case .all:
            break
        case .selfEcho: try await runSelfScenario(options: options, into: &results)
        case .cross: try await runCrossScenario(options: options, into: &results)
        case .format: try await runFormatScenario(options: options, into: &results)
        case .pin: try await runPinScenario(options: options, into: &results)
        case .agc: try await runAGCScenario(options: options, into: &results)
        case .tap: try await runTapScenario(options: options, into: &results)
        case .perf: try await runPerfScenario(options: options, into: &results)
        }
    }

    // MARK: - Scenario: self (loopback self-echo)

    private func runSelfScenario(options: AECSpikeOptions, into results: inout SpikeResultsJSON) async throws {
        guard options.durationSec >= Self.minAnalyzableDurationSec else {
            throw SpikeError.unavailable("'self' needs --spike-duration >= \(Self.minAnalyzableDurationSec)s " +
                "(must skip the \(Self.convergenceSkipFrames)-frame convergence window and still see 2 full " +
                "burst periods); got \(options.durationSec)s.")
        }

        let device = try resolveInputDevice(options.inputSelection)
        let deviceLabel = inputDeviceLabel(device)

        print("Please stay SILENT near the microphone (don't speak) while this scenario runs — it")
        print("measures how well Voice Processing I/O cancels NoNoise's OWN played-back burst.")
        print("Input device: \(deviceLabel)")
        let burst = makeBurstSignal(durationSec: options.durationSec, sampleRate: 48_000)

        print("Pass 1/2: Voice Processing OFF (baseline, uncancelled echo)...")
        let off = try await recordPass(engineOptions: SpikeEngineOptions(voiceProcessing: false, inputDevice: device),
                                       durationSec: options.durationSec, playback: burst)
        let offPath = path(options, "spike-self-off.wav")
        try writeWav(off.samples, sampleRate: off.sampleRate, to: offPath)

        // AGC OFF for the ON pass: AGC's own gain riding would inject a gain change into the
        // ON-pass recording that has nothing to do with echo cancellation, contaminating a
        // straight absolute-RMS comparison against the (also-unlevelled) OFF pass.
        print("Pass 2/2: Voice Processing ON (should cancel the echo)...")
        let on = try await recordPass(engineOptions: SpikeEngineOptions(voiceProcessing: true, agcEnabled: false, inputDevice: device),
                                      durationSec: options.durationSec, playback: burst)
        let onPath = path(options, "spike-self-on.wav")
        try writeWav(on.samples, sampleRate: on.sampleRate, to: onPath)

        let offReference = resample(burst, fromRate: 48_000, toRate: off.sampleRate)
        let offMaxLag = scaledFrames(Self.correlationMaxLagFrames48k, forSampleRate: off.sampleRate)
        let offCorr = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: offReference, recorded: off.samples, maxLagFrames: offMaxLag)

        // The ON-pass recording's OWN correlation lag is unreliable once VPIO starts cancelling
        // the echo — with less echo left to correlate against, the "best" lag can drift to a
        // noise-driven false peak, which would then misalign the ON/OFF windowing entirely. The
        // playback schedule and the acoustic path delay are identical in both passes, so the
        // OFF-pass lag (converted to the ON recording's sample rate, in case VPIO forced a
        // different one) is the reliable choice for BOTH `burstOnOffRMS` calls below. The ON
        // recording's own correlation is still computed and reported for visibility only.
        let onReference = resample(burst, fromRate: 48_000, toRate: on.sampleRate)
        let onMaxLag = scaledFrames(Self.correlationMaxLagFrames48k, forSampleRate: on.sampleRate)
        let onCorr = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: onReference, recorded: on.samples, maxLagFrames: onMaxLag)
        let sharedLagOnRate = convertFrameCount(offCorr.lagFrames, fromRate: off.sampleRate, toRate: on.sampleRate)

        let offPeriod = scaledFrames(Self.burstPeriodFrames, forSampleRate: off.sampleRate)
        let offOn = scaledFrames(Self.burstOnFrames, forSampleRate: off.sampleRate)
        let offSkip = scaledFrames(Self.convergenceSkipFrames, forSampleRate: off.sampleRate)
        let onPeriod = scaledFrames(Self.burstPeriodFrames, forSampleRate: on.sampleRate)
        let onOn = scaledFrames(Self.burstOnFrames, forSampleRate: on.sampleRate)
        let onSkip = scaledFrames(Self.convergenceSkipFrames, forSampleRate: on.sampleRate)

        // Baseline echo level = ON-window RMS of the UNCANCELLED (VPIO-off) recording.
        let (baselineOnRMS, _) = AECSpikeAnalysis.burstOnOffRMS(recorded: off.samples, lagFrames: offCorr.lagFrames,
                                                                periodFrames: offPeriod, onFrames: offOn, skipFrames: offSkip)
        // Residual echo level = ON-window RMS of the VPIO-cancelled recording, windowed using the
        // OFF pass's lag (see above); the OFF-window RMS of that SAME recording is the floor noise
        // while VPIO is engaged (informational).
        let (residualOnRMS, residualOffRMS) = AECSpikeAnalysis.burstOnOffRMS(recorded: on.samples, lagFrames: sharedLagOnRate,
                                                                             periodFrames: onPeriod, onFrames: onOn, skipFrames: onSkip)

        let erle = AECSpikeAnalysis.erleDb(residualRMS: residualOnRMS, baselineEchoRMS: baselineOnRMS)
        let residualDbfs = AECSpikeAnalysis.dbfs(residualOnRMS)
        let verdict = AECSpikeAnalysis.selfEchoVerdict(erleDb: erle, residualDbfs: residualDbfs)

        var warning: String?
        if offCorr.peak < Self.selfEchoOffCorrelationWarningThreshold {
            warning = "OFF-pass correlation peak (\(offCorr.peak)) is below " +
                "\(Self.selfEchoOffCorrelationWarningThreshold) — the burst may not have been captured " +
                "cleanly (wrong device? no speaker output? muted?); the ERLE/verdict below may be unreliable."
        }

        results.selfEcho = SelfEchoResult(
            offRecordingPath: offPath, onRecordingPath: onPath,
            offSampleRate: off.sampleRate, onSampleRate: on.sampleRate,
            inputDeviceUID: device?.uid, inputDeviceName: deviceLabel,
            offRecorderStatus: off.status, onRecorderStatus: on.status,
            correlationLagFramesOff: offCorr.lagFrames, correlationPeakOff: offCorr.peak,
            correlationLagFramesOn: onCorr.lagFrames, correlationPeakOn: onCorr.peak,
            baselineOnRMS: baselineOnRMS, residualOnRMS: residualOnRMS, residualOffRMS: residualOffRMS,
            erleDb: erle, residualDbfs: residualDbfs, verdict: verdict.rawValue, warning: warning)
        print(String(format: "ERLE=%.1f dB   residual=%.1f dBFS   verdict=%@", erle, residualDbfs, verdict.rawValue))
        if let warning { print("WARNING: \(warning)") }
    }

    // MARK: - Scenario: cross (another process's playback)

    private func runCrossScenario(options: AECSpikeOptions, into results: inout SpikeResultsJSON) async throws {
        let device = try resolveInputDevice(options.inputSelection)

        let referencePath = path(options, "spike-cross-reference.wav")
        let reference = makeBurstSignal(durationSec: options.durationSec, sampleRate: 48_000)
        try writeWav(reference, sampleRate: 48_000, to: referencePath)

        print("Playing the reference burst via a SEPARATE process (afplay) while recording — first")
        print("WITHOUT voice processing (control: proves the burst actually reaches the mic), then")
        print("WITH voice processing. Comparing the two shows whether VPIO's echo cancellation also")
        print("covers OTHER processes' output (its reference may be limited to this process's own).")

        // One afplay launch per pass; the defer guarantees the player never outlives its pass.
        // afplay is launched from `onRecordingStarted` — i.e. only once the engine is live — so
        // its signal lands at a small POSITIVE lag the correlation search can actually find.
        func recordWhilePlaying(voiceProcessing: Bool) async throws -> RecordedPass {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [referencePath]
            defer {
                if player.isRunning { player.terminate() }
                if player.processIdentifier != 0 { player.waitUntilExit() }
            }
            return try await recordPass(engineOptions: SpikeEngineOptions(voiceProcessing: voiceProcessing, inputDevice: device),
                                        durationSec: options.durationSec,
                                        onRecordingStarted: { try player.run() })
        }

        print("Pass 1/2: Voice Processing OFF (control)...")
        let baseline = try await recordWhilePlaying(voiceProcessing: false)
        let baselinePath = path(options, "spike-cross-baseline.wav")
        try writeWav(baseline.samples, sampleRate: baseline.sampleRate, to: baselinePath)

        print("Pass 2/2: Voice Processing ON...")
        let captured = try await recordWhilePlaying(voiceProcessing: true)
        let recordingPath = path(options, "spike-cross-recorded.wav")
        try writeWav(captured.samples, sampleRate: captured.sampleRate, to: recordingPath)

        let baselineReference = resample(reference, fromRate: 48_000, toRate: baseline.sampleRate)
        let baselineMaxLag = scaledFrames(Self.correlationMaxLagFrames48k, forSampleRate: baseline.sampleRate)
        let baseCorr = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: baselineReference, recorded: baseline.samples, maxLagFrames: baselineMaxLag)
        // The control pass must show the burst in the mic signal, or the ON pass proves nothing
        // (afplay silent, output on another device, volume at zero, ...).
        let baselineCaptured = baseCorr.peak >= Self.selfEchoOffCorrelationWarningThreshold

        let referenceForAnalysis = resample(reference, fromRate: 48_000, toRate: captured.sampleRate)
        let maxLag = scaledFrames(Self.correlationMaxLagFrames48k, forSampleRate: captured.sampleRate)
        let corr = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: referenceForAnalysis, recorded: captured.samples, maxLagFrames: maxLag)
        let detected = AECSpikeAnalysis.crossProcessEchoDetected(correlationPeak: corr.peak)

        let note: String? = baselineCaptured ? nil :
            "Control pass correlation (\(baseCorr.peak)) is below \(Self.selfEchoOffCorrelationWarningThreshold) — the afplay " +
            "burst never reached the mic (volume down? other output device?), so echoDetected is meaningless."
        results.cross = CrossResult(recordingPath: recordingPath, baselineRecordingPath: baselinePath,
                                    referencePath: referencePath,
                                    sampleRate: captured.sampleRate, recorderStatus: captured.status,
                                    baselineCorrelationPeak: baseCorr.peak, baselineCorrelationLagFrames: baseCorr.lagFrames,
                                    correlationPeak: corr.peak, correlationLagFrames: corr.lagFrames,
                                    echoDetected: detected, baselineCaptured: baselineCaptured, note: note)
        print(String(format: "Cross-process: control peak=%.3f (captured=%@) | VPIO-on peak=%.3f lag=%d echoDetected=%@",
                    baseCorr.peak, baselineCaptured ? "yes" : "NO", corr.peak, corr.lagFrames, detected ? "true" : "false"))
        if let note { print("NOTE: \(note)") }
    }

    // MARK: - Scenario: format

    private func runFormatScenario(options: AECSpikeOptions, into results: inout SpikeResultsJSON) async throws {
        let device = try resolveInputDevice(options.inputSelection)

        let offEngine = try buildEngine(SpikeEngineOptions(voiceProcessing: false, inputDevice: device))
        offEngine.prepare()
        let offIn = offEngine.inputNode.inputFormat(forBus: 0)
        let offOut = offEngine.outputNode.outputFormat(forBus: 0)
        offEngine.stop()
        offEngine.reset()

        let onEngine = try buildEngine(SpikeEngineOptions(voiceProcessing: true, inputDevice: device))
        onEngine.prepare()
        let onIn = onEngine.inputNode.inputFormat(forBus: 0)
        let onOut = onEngine.outputNode.outputFormat(forBus: 0)

        // Pre-allocated ASBD + a plain Int32 "written" flag instead of an `AVAudioFormat?` var:
        // `AVAudioFormat` is an Objective-C class, so assigning one from inside the tap callback
        // would be an ARC retain/release on the realtime IO thread. `buffer.format.streamDescription`
        // is an `UnsafePointer<AudioStreamBasicDescription>` into the format's own backing storage;
        // `.pointee` copies the plain C struct — no ARC, no allocation.
        let firstFormatBox = UnsafeMutablePointer<AudioStreamBasicDescription>.allocate(capacity: 1)
        firstFormatBox.initialize(to: AudioStreamBasicDescription())
        let firstFormatWrittenBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        firstFormatWrittenBox.initialize(to: 0)
        defer {
            firstFormatBox.deinitialize(count: 1)
            firstFormatBox.deallocate()
            firstFormatWrittenBox.deinitialize(count: 1)
            firstFormatWrittenBox.deallocate()
        }

        onEngine.inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSizeFrames, format: nil) { buffer, _ in
            if firstFormatWrittenBox.pointee == 0 {
                firstFormatBox.pointee = buffer.format.streamDescription.pointee
                firstFormatWrittenBox.pointee = 1
            }
        }
        onEngine.prepare()
        do {
            try onEngine.start()
        } catch {
            onEngine.inputNode.removeTap(onBus: 0)
            throw SpikeError.engineStartFailed(error.localizedDescription)
        }
        defer {
            onEngine.stop()
            onEngine.inputNode.removeTap(onBus: 0)
            onEngine.reset()
        }

        let deadline = Date().addingTimeInterval(Self.formatTapWaitTimeoutSec)
        while firstFormatWrittenBox.pointee == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let onFirstTapBufferFormat: String?
        if firstFormatWrittenBox.pointee != 0 {
            var asbd = firstFormatBox.pointee
            onFirstTapBufferFormat = withUnsafePointer(to: &asbd) { ptr in
                AVAudioFormat(streamDescription: ptr).map { "\($0)" }
            }
        } else {
            onFirstTapBufferFormat = nil
        }

        results.format = FormatResult(offInputFormat: "\(offIn)", offOutputFormat: "\(offOut)",
                                      onInputFormat: "\(onIn)", onOutputFormat: "\(onOut)",
                                      onFirstTapBufferFormat: onFirstTapBufferFormat)
        print("OFF input format:  \(offIn)")
        print("OFF output format: \(offOut)")
        print("ON  input format:  \(onIn)")
        print("ON  output format: \(onOut)")
        print("ON  first tap buffer format: \(onFirstTapBufferFormat ?? "n/a (no buffer within \(Int(Self.formatTapWaitTimeoutSec))s)")")
    }

    // MARK: - Scenario: pin (manual input device under VPIO)

    private func runPinScenario(options: AECSpikeOptions, into results: inout SpikeResultsJSON) async throws {
        let devices = Self.enumerateInputDevices()
        print("Available input devices:")
        for d in devices { print(" - \(d.name)  [\(d.uid)]") }

        // A `--spike-input` that matches nothing is a hard error (via `resolveInputDevice`); no
        // `--spike-input` at all falls back to the first enumerated device — that fallback is
        // pin's OWN documented default (this scenario's whole job is exercising device pinning, so
        // it needs SOME target when none is specified), not a silently-swallowed resolution failure.
        let requested = try resolveInputDevice(options.inputSelection)
        guard let target = requested ?? devices.first else {
            results.pin = PinResult(availableInputDevices: devices.map { $0.name }, targetDeviceUID: nil,
                                    targetDeviceName: nil, pinStatus: -1, pinSucceededSemantically: false,
                                    recorderStatus: .ranDry, knownErrorNote: "No input devices enumerated.")
            print("No input devices available to pin.")
            return
        }

        guard let deviceID = Self.haldeviceID(forUID: target.uid) else {
            results.pin = PinResult(availableInputDevices: devices.map { $0.name }, targetDeviceUID: target.uid,
                                    targetDeviceName: target.name, pinStatus: -1, pinSucceededSemantically: false,
                                    recorderStatus: .ranDry, knownErrorNote: "Could not resolve an AudioObjectID for this UID.")
            print("Could not resolve AudioObjectID for '\(target.name)'.")
            return
        }

        let engine = try buildEngine(SpikeEngineOptions(voiceProcessing: true, inputDevice: nil))
        engine.prepare()
        // Deliberately NOT routed through `buildEngine`'s throwing device-pin path: this scenario's
        // entire purpose is recording and reporting the pin OSStatus, success or failure, rather
        // than aborting on a bad one.
        let status = Self.pinInputDevice(engine: engine, deviceID: deviceID)

        let recorder = SpikeRecorder(capacityFrames: Int(Self.pinRecordingDurationSec) * Self.recorderCapacitySafetySampleRate)
        engine.inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSizeFrames, format: nil) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            recorder.append(channel, count: Int(buffer.frameLength))
        }
        var started = true
        do { try engine.start() } catch { started = false }
        defer {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        if started {
            try? await Task.sleep(nanoseconds: nanoseconds(forSeconds: Self.pinRecordingDurationSec))
        }

        let recorded = recorder.snapshot()
        var rms: Float = 0
        if !recorded.isEmpty { vDSP_rmsqv(recorded, 1, &rms, vDSP_Length(recorded.count)) }

        var note: String?
        if status == kAudioUnitErr_FailedInitialization {
            note = "kAudioUnitErr_FailedInitialization (-10875): the audio unit refused to (re)initialize for this device — often a format/device mismatch."
        } else if status == kAudioUnitErr_NoConnection {
            note = "kAudioUnitErr_NoConnection (-10876): the unit has no valid connection for this scope/element."
        } else if status != noErr {
            note = "AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice) failed with OSStatus \(status)."
        }

        let semanticSuccess = started && rms > 0
        results.pin = PinResult(availableInputDevices: devices.map { $0.name }, targetDeviceUID: target.uid,
                                targetDeviceName: target.name, pinStatus: status,
                                pinSucceededSemantically: semanticSuccess, recorderStatus: recorder.status,
                                knownErrorNote: note)
        print("Pin target: \(target.name)  status=\(status)  semanticSuccess=\(semanticSuccess)")
        if let note { print(note) }
    }

    // MARK: - Scenario: agc

    private func runAGCScenario(options: AECSpikeOptions, into results: inout SpikeResultsJSON) async throws {
        let device = try resolveInputDevice(options.inputSelection)
        let deviceLabel = inputDeviceLabel(device)
        let duration = Self.agcRecordingDurationSec

        print("Input device: \(deviceLabel)")
        print("Speak continuously at a STEADY volume for \(Int(duration))s (pass 1/2: AGC ON)...")
        let on = try await recordPass(engineOptions: SpikeEngineOptions(voiceProcessing: true, agcEnabled: true, inputDevice: device),
                                      durationSec: duration)
        let onPath = path(options, "spike-agc-on.wav")
        try writeWav(on.samples, sampleRate: on.sampleRate, to: onPath)

        print("Speak continuously at the SAME steady volume for \(Int(duration))s (pass 2/2: AGC OFF)...")
        let off = try await recordPass(engineOptions: SpikeEngineOptions(voiceProcessing: true, agcEnabled: false, inputDevice: device),
                                       durationSec: duration)
        let offPath = path(options, "spike-agc-off.wav")
        try writeWav(off.samples, sampleRate: off.sampleRate, to: offPath)

        let onDenoisedPath = path(options, "spike-agc-on-denoised.wav")
        let offDenoisedPath = path(options, "spike-agc-off-denoised.wav")
        try await denoiseOffline(on.samples, sampleRate: on.sampleRate, to: onDenoisedPath)
        try await denoiseOffline(off.samples, sampleRate: off.sampleRate, to: offDenoisedPath)

        let onVariance = Self.variance(AECSpikeAnalysis.windowedRMS(on.samples, windowFrames: Self.agcWindowFrames))
        let offVariance = Self.variance(AECSpikeAnalysis.windowedRMS(off.samples, windowFrames: Self.agcWindowFrames))

        results.agc = AGCResult(onRecordingPath: onPath, offRecordingPath: offPath,
                                onDenoisedPath: onDenoisedPath, offDenoisedPath: offDenoisedPath,
                                inputDeviceUID: device?.uid, inputDeviceName: deviceLabel,
                                onRecorderStatus: on.status, offRecorderStatus: off.status,
                                onWindowedRMSVariance: onVariance, offWindowedRMSVariance: offVariance)
        print(String(format: "AGC ON windowed-RMS variance=%.6f   AGC OFF windowed-RMS variance=%.6f", onVariance, offVariance))
    }

    // MARK: - Scenario: tap (coexistence with IncomingCleanupEngine)

    private func runTapScenario(options: AECSpikeOptions, into results: inout SpikeResultsJSON) async throws {
        guard #available(macOS 14.4, *) else {
            let note = "Clean Incoming (IncomingCleanupEngine) requires macOS 14.4+; this host is older."
            results.tap = TapResult(available: false, started: false, telemetrySamples: [], note: note)
            print(note)
            return
        }

        let device = try resolveInputDevice(options.inputSelection)
        let engine = try buildEngine(SpikeEngineOptions(voiceProcessing: true, inputDevice: device))
        engine.prepare()
        // Best-effort: keep VPIO capture running alongside Clean Incoming. A failure here doesn't
        // invalidate the coexistence check itself, so it's non-fatal for this scenario.
        try? engine.start()
        defer { engine.stop(); engine.reset() }

        let incoming = IncomingCleanupEngine()
        let started = incoming.start()
        defer { incoming.stop() }

        guard started else {
            let note = """
            IncomingCleanupEngine.start() returned false — most likely TCC (audio-capture consent) \
            was never granted, which is expected for a bare CLI binary run outside NoNoiseMac.app \
            (no bundled Info.plist usage string, so macOS never showed the consent prompt). \
            Workaround: enable "Clean Incoming" once in the bundled NoNoiseMac.app (grants + \
            remembers consent for this Mac), then re-run this scenario.
            """
            results.tap = TapResult(available: true, started: false, telemetrySamples: [], note: note)
            print(note)
            return
        }

        print("Clean Incoming is running alongside VPIO capture. Optionally play audio now")
        print("(e.g. `afplay <file>` in another terminal) to see the telemetry level move.")
        var samples: [Float] = []
        for _ in 0..<Self.tapTelemetrySampleCount {
            try? await Task.sleep(nanoseconds: nanoseconds(forSeconds: Self.tapTelemetrySampleIntervalSec))
            samples.append(incoming.telemetryLevel)
        }
        results.tap = TapResult(available: true, started: true, telemetrySamples: samples, note: nil)
        print("Telemetry samples: \(samples)")
    }

    // MARK: - Scenario: perf

    private func runPerfScenario(options: AECSpikeOptions, into results: inout SpikeResultsJSON) async throws {
        guard options.durationSec >= Self.minAnalyzableDurationSec else {
            throw SpikeError.unavailable("'perf' needs --spike-duration >= \(Self.minAnalyzableDurationSec)s " +
                "(the loop-latency estimate needs a real correlation lag, which needs the same burst " +
                "coverage as 'self'); got \(options.durationSec)s.")
        }

        let device = try resolveInputDevice(options.inputSelection)

        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)

        let burst = makeBurstSignal(durationSec: options.durationSec, sampleRate: 48_000)
        let engine = try buildEngine(SpikeEngineOptions(voiceProcessing: true, inputDevice: device))

        let capacityFrames = Int(options.durationSec * Double(Self.recorderCapacitySafetySampleRate)) + Self.recorderCapacitySafetySampleRate
        let recorder = SpikeRecorder(capacityFrames: capacityFrames)
        // Same two format rules as `recordPass` (they are what makes a VPIO engine with a playback
        // graph start at all — see the -10875 notes there): explicit mono tap format, fixed
        // standard stereo on the mixer→output connection.
        engine.inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSizeFrames,
                                    format: AudioUtils.shared.processingFormat) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            recorder.append(channel, count: Int(buffer.frameLength))
        }

        let playbackSource = SpikePlaybackSource(burst)
        let sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            playbackSource.fill(data, count: Int(frameCount))
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: AudioUtils.shared.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        engine.prepare()

        let startWallBegin = DispatchTime.now()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw SpikeError.engineStartFailed(error.localizedDescription)
        }
        let startWallEnd = DispatchTime.now()
        let engineStartMs = Double(startWallEnd.uptimeNanoseconds &- startWallBegin.uptimeNanoseconds) / 1_000_000

        defer {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }

        try await Task.sleep(nanoseconds: nanoseconds(forSeconds: options.durationSec))
        let sampleRate = engine.inputNode.inputFormat(forBus: 0).sampleRate

        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        let userDelta = Self.rusageSeconds(usageAfter.ru_utime) - Self.rusageSeconds(usageBefore.ru_utime)
        let sysDelta = Self.rusageSeconds(usageAfter.ru_stime) - Self.rusageSeconds(usageBefore.ru_stime)

        let recorded = recorder.snapshot()
        let referenceForAnalysis = resample(burst, fromRate: 48_000, toRate: sampleRate)
        let maxLag = scaledFrames(Self.correlationMaxLagFrames48k, forSampleRate: sampleRate)
        let corr = AECSpikeAnalysis.normalizedCrossCorrelationPeak(reference: referenceForAnalysis, recorded: recorded, maxLagFrames: maxLag)
        // This is a VPIO-ON run, so a WORKING echo canceller removes the very signal the lag
        // estimate needs — a sub-threshold peak means the lag is noise-driven, and the latency
        // estimate is reported as -1 (unavailable) rather than a made-up number.
        let lagReliable = corr.peak >= Self.selfEchoOffCorrelationWarningThreshold
        let loopLatencyMs = (lagReliable && sampleRate > 0) ? Double(corr.lagFrames) / sampleRate * 1000 : -1

        results.perf = PerfResult(cpuUserSecondsDelta: userDelta, cpuSystemSecondsDelta: sysDelta,
                                  engineStartWallMs: engineStartMs, loopLatencyMsEstimate: loopLatencyMs,
                                  recorderStatus: recorder.status)
        print(String(format: "perf: cpu user=%.3fs sys=%.3fs engineStart=%.1fms loopLatency≈%.1fms",
                    userDelta, sysDelta, engineStartMs, loopLatencyMs))
    }

    // MARK: - Signal generation

    /// Periodic white-noise burst: `burstPeriodFrames` period, first `burstOnFrames` ON (with a
    /// short linear fade at each edge to avoid a click that would itself falsely correlate), then
    /// silence for the rest of the period. Frame counts are scaled to `sampleRate` so the SAME real
    /// time schedule holds regardless of the actual playback rate.
    func makeBurstSignal(durationSec: Double, sampleRate: Double) -> [Float] {
        let totalFrames = max(1, Int(durationSec * sampleRate))
        let period = max(1, scaledFrames(Self.burstPeriodFrames, forSampleRate: sampleRate))
        let onLen = max(1, scaledFrames(Self.burstOnFrames, forSampleRate: sampleRate))
        let fadeLen = max(1, Int(Self.burstFadeMs / 1000.0 * sampleRate))
        var signal = [Float](repeating: 0, count: totalFrames)
        var rng = SplitMix64(seed: 0x5EED_1234_ABCD_0001)
        for i in 0..<totalFrames {
            let phase = i % period
            guard phase < onLen else { continue }
            var sample = (Float(rng.nextUniformUnitInterval()) * 2 - 1) * Self.burstAmplitude
            if phase < fadeLen {
                sample *= Float(phase) / Float(fadeLen)
            } else if phase >= onLen - fadeLen {
                sample *= Float(onLen - phase) / Float(fadeLen)
            }
            signal[i] = sample
        }
        return signal
    }

    /// Scales a frame count defined at 48 kHz to an arbitrary sample rate, preserving real time —
    /// used because Voice Processing I/O (or a non-48 kHz input device) can force capture into a
    /// different native rate than the 48 kHz the rest of NoNoise standardizes on.
    private func scaledFrames(_ frames48k: Int, forSampleRate sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return frames48k }
        return max(1, Int((Double(frames48k) * sampleRate / 48_000.0).rounded()))
    }

    /// Converts a frame count from one sample rate's frame axis to another's, preserving real
    /// time — used to carry the OFF pass's correlation lag over to the ON pass's (possibly
    /// different) sample rate.
    private func convertFrameCount(_ frames: Int, fromRate: Double, toRate: Double) -> Int {
        guard fromRate > 0 else { return frames }
        return max(0, Int((Double(frames) * toRate / fromRate).rounded()))
    }

    /// Resample a mono Float32 buffer between sample rates via `AVAudioConverter`. Used only in
    /// spike analysis setup (never on a realtime thread) — correlating a 48 kHz reference against a
    /// recording captured at a different native rate would otherwise misalign every frame index.
    private func resample(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard fromRate > 0, toRate > 0, abs(fromRate - toRate) > 0.5, !samples.isEmpty else { return samples }
        guard let fromFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 1, interleaved: false),
              let toFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: fromFormat, to: toFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: fromFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let inputChannel = inputBuffer.floatChannelData?[0] else {
            return samples
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            inputChannel.update(from: base, count: samples.count)
        }
        let outCapacity = AVAudioFrameCount(Double(samples.count) * toRate / fromRate) + Self.resampleCapacityPaddingFrames
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: toFormat, frameCapacity: outCapacity) else { return samples }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, let outChannel = outputBuffer.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: outChannel, count: Int(outputBuffer.frameLength)))
    }

    private func nanoseconds(forSeconds seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    // MARK: - Offline DeepFilterNet pass (agc scenario)

    /// Runs `samples` through a fresh `DeepFilterNetDSP` instance (DFN only, no `VoiceChain` — same
    /// scope as `IncomingCleanupEngine`/`SpeakerCleanupEngine`) and writes the result as a WAV.
    /// Mirrors `AudioFileDenoiser`'s chunked-processing shape, simplified for an already-decoded
    /// in-memory mono buffer.
    private func denoiseOffline(_ samples: [Float], sampleRate: Double, to outputPath: String) async throws {
        let dfnInput = abs(sampleRate - 48_000) > 0.5 ? resample(samples, fromRate: sampleRate, toRate: 48_000) : samples
        let dsp = DeepFilterNetDSP()
        guard await dsp.waitUntilReady() else {
            throw SpikeError.unavailable("DeepFilterNet model did not finish loading in time for '\(outputPath)'.")
        }
        var output = [Float](repeating: 0, count: dfnInput.count)
        let chunk = Self.dfnOfflineChunkFrames
        dfnInput.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                guard let inBase = inBuf.baseAddress, let outBase = outBuf.baseAddress else { return }
                var offset = 0
                while offset < dfnInput.count {
                    let n = min(chunk, dfnInput.count - offset)
                    dsp.process(input: inBase + offset, count: n, output: outBase + offset)
                    offset += n
                }
            }
        }
        try writeWav(output, sampleRate: 48_000, to: outputPath)
    }

    // MARK: - Input device resolution

    /// Resolves `--spike-input` against the live device list. `nil` (no `--spike-input` given)
    /// means "use the system default" and is NOT an error. A non-nil query that matches NOTHING
    /// THROWS instead of silently falling back to the system default — previously a typo'd
    /// `--spike-input` value would just silently record from the wrong (default) device with
    /// nothing in the output calling that out.
    private func resolveInputDevice(_ query: String?) throws -> SpikeInputDevice? {
        guard let query else { return nil }
        guard let match = Self.matchInputDevice(query, in: Self.enumerateInputDevices()) else {
            throw SpikeError.inputDeviceNotFound(query)
        }
        return match
    }

    private func inputDeviceLabel(_ device: SpikeInputDevice?) -> String {
        device?.name ?? "system default"
    }

    // MARK: - Engine construction

    private struct SpikeEngineOptions {
        var voiceProcessing: Bool
        var agcEnabled: Bool = true
        var inputDevice: SpikeInputDevice?
    }

    /// Builds (but does not start) an `AVAudioEngine`, optionally enabling Voice Processing I/O and
    /// pinning a manual input device. VPIO must be toggled, and the device pin applied, BEFORE
    /// `engine.start()` — both are documented as stopped-engine-only operations. Throws (rather
    /// than silently ignoring) if `inputDevice` was resolved from the live device list moments ago
    /// but can no longer be translated to an `AudioObjectID`, or if pinning it fails outright.
    private func buildEngine(_ opts: SpikeEngineOptions) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if opts.voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                throw SpikeError.voiceProcessingSetupFailed(error.localizedDescription)
            }
            // `isVoiceProcessingAGCEnabled` has been available since macOS 10.15 — the SAME OS
            // version as `setVoiceProcessingEnabled` itself (confirmed against the AVFAudio SDK
            // header) — so it needs no `#available` gate.
            inputNode.isVoiceProcessingAGCEnabled = opts.agcEnabled
        }

        if let device = opts.inputDevice {
            guard let deviceID = Self.haldeviceID(forUID: device.uid) else {
                throw SpikeError.inputDeviceNotFound(device.name)
            }
            engine.prepare()
            let status = Self.pinInputDevice(engine: engine, deviceID: deviceID)
            guard status == noErr else {
                throw SpikeError.inputDevicePinFailed(device.name, status)
            }
        }

        return engine
    }

    /// Pin the engine's input to a specific HAL device via `kAudioOutputUnitProperty_CurrentDevice`
    /// on the input node's underlying audio unit (global scope, element 0) — the same property/scope
    /// `SpeakerCleanupEngine` uses to pin its OUTPUT unit; the AUHAL unit backing an `AVAudioEngine`
    /// I/O node uses this property for either direction. MUST be called before `engine.start()`.
    @discardableResult
    private static func pinInputDevice(engine: AVAudioEngine, deviceID: AudioObjectID) -> OSStatus {
        guard let audioUnit = engine.inputNode.audioUnit else { return OSStatus(-1) }
        var device = deviceID
        return AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &device, UInt32(MemoryLayout<AudioObjectID>.size))
    }

    // MARK: - Recording pass (shared by self / cross / agc / perf)

    private struct RecordedPass {
        let samples: [Float]
        let sampleRate: Double
        let status: SpikeRecorderStatus
    }

    /// Builds an engine per `engineOptions`, records `durationSec` of input (optionally playing
    /// `playback` simultaneously through the SAME engine's output), then tears the engine down via
    /// `defer` (so a thrown/cancelled `Task.sleep` still cleans up). Recording uses a pre-allocated
    /// `SpikeRecorder` (never a growing Swift array) from the tap callback, and playback (when
    /// present) uses a pre-allocated `SpikePlaybackSource` from the source-node render callback —
    /// matching the project's no-realtime-allocation rule.
    private func recordPass(engineOptions: SpikeEngineOptions, durationSec: Double,
                            playback: [Float]? = nil,
                            onRecordingStarted: (() throws -> Void)? = nil) async throws -> RecordedPass {
        let engine = try buildEngine(engineOptions)
        let inputNode = engine.inputNode

        let capacityFrames = Int(durationSec * Double(Self.recorderCapacitySafetySampleRate)) + Self.recorderCapacitySafetySampleRate
        let recorder = SpikeRecorder(capacityFrames: capacityFrames)
        // Explicit mono 48 kHz tap format: with Voice Processing enabled the input node reports a
        // multi-channel internal format (7ch observed); leaving the tap at `nil` makes that the
        // client-side input format, which then mismatches the 2ch output graph and fails
        // engine.start() with -10875 ("client-side input and output formats do not match").
        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSizeFrames,
                             format: AudioUtils.shared.processingFormat) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            recorder.append(channel, count: Int(buffer.frameLength))
        }

        var sourceNode: AVAudioSourceNode?
        if let playback {
            let playbackSource = SpikePlaybackSource(playback)
            let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                playbackSource.fill(data, count: Int(frameCount))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: AudioUtils.shared.processingFormat)
            // Explicit fixed-format connection: under Voice Processing, `format: nil` (the mixer's
            // own format) can mismatch the VPIO output element's client format and fail
            // engine.start() with -10875 — and `outputNode.outputFormat(forBus: 0)` is not yet
            // valid at connect time (0 Hz/0 ch → NSException), so a fixed standard format is used.
            engine.connect(engine.mainMixerNode, to: engine.outputNode,
                           format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            sourceNode = node
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SpikeError.engineStartFailed(error.localizedDescription)
        }

        defer {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            engine.reset()
        }

        // Runs only once recording is live: an external sound source (afplay) started BEFORE this
        // point would put its signal at a NEGATIVE lag relative to the recording, which the
        // positive-lag-only correlation search can never find.
        try onRecordingStarted?()

        try await Task.sleep(nanoseconds: nanoseconds(forSeconds: durationSec))

        let sampleRate = inputNode.inputFormat(forBus: 0).sampleRate
        _ = sourceNode   // kept alive until scope exit (past the defer's engine.reset())
        return RecordedPass(samples: recorder.snapshot(), sampleRate: sampleRate, status: recorder.status)
    }

    // MARK: - WAV output + results file

    private func path(_ options: AECSpikeOptions, _ filename: String) -> String {
        (options.outputDir as NSString).appendingPathComponent(filename)
    }

    private func writeWav(_ samples: [Float], sampleRate: Double, to filePath: String) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: max(1, sampleRate), channels: 1, interleaved: false) else {
            throw SpikeError.unavailable("Could not create a WAV format for \(filePath).")
        }
        let url = URL(fileURLWithPath: filePath)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            throw SpikeError.unavailable("Could not allocate a WAV buffer for \(filePath).")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if samples.count > 0, let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                channel.update(from: base, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    private func writeResults(_ results: SpikeResultsJSON, to outputDir: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(results)
            let resultsPath = (outputDir as NSString).appendingPathComponent("spike-results.json")
            try data.write(to: URL(fileURLWithPath: resultsPath))
            print("\nWrote results: \(resultsPath)")
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } catch {
            print("Warning: could not write spike-results.json: \(error)")
        }
    }

    private static func variance(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let sumSquaredDeviation = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSquaredDeviation / Float(values.count)
    }

    private static func rusageSeconds(_ tv: timeval) -> Double {
        Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    // MARK: - HAL input device enumeration
    //
    // Non-realtime CoreAudio property queries. NOT "main-thread only" despite `VoiceIOSpikeRunner`
    // not being `@MainActor` — `run(_:)` and its scenario methods are plain `async` functions, so
    // they (and these helpers, called from them) resume on whatever thread Swift's cooperative
    // thread pool happens to schedule, not necessarily the main thread. That's fine here: these are
    // one-shot HAL queries, not state shared with a realtime callback.

    private struct SpikeInputDevice: Equatable {
        let uid: String
        let name: String
    }

    private static func enumerateInputDevices() -> [SpikeInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs) == noErr else { return [] }

        var results: [SpikeInputDevice] = []
        for id in deviceIDs {
            guard hasInputStreams(id), let uid = deviceUID(for: id) else { continue }
            results.append(SpikeInputDevice(uid: uid, name: deviceName(for: id) ?? uid))
        }
        return results
    }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
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

    /// UID exact match first, then a case-insensitive substring match on the device name.
    private static func matchInputDevice(_ query: String, in devices: [SpikeInputDevice]) -> SpikeInputDevice? {
        if let exact = devices.first(where: { $0.uid == query }) { return exact }
        let lowered = query.lowercased()
        return devices.first(where: { $0.name.lowercased().contains(lowered) })
    }
}

// MARK: - Real-time-safe recording sink

/// Diagnostic status of a `SpikeRecorder` at snapshot time, surfaced in the JSON report so a
/// silent "recorded nothing" or "recording was truncated" doesn't masquerade as a normal result.
private enum SpikeRecorderStatus: String, Encodable {
    /// Wrote at least one frame and never hit capacity.
    case ok
    /// Hit capacity — some trailing frames were dropped (the caller asked for more than fit, or
    /// ran longer than expected).
    case overflowed
    /// Never received a single frame — the tap likely never fired at all (wrong/dead device,
    /// engine never actually started producing IO despite `start()` succeeding, etc).
    case ranDry
}

/// Pre-allocated recording sink for a spike scenario's `installTap` callback. Fixed capacity —
/// once full, further frames are silently dropped rather than growing. Mirrors the project's
/// real-time rule: no Swift array append/allocation inside an audio callback (see
/// `IncomingCleanupEngine`'s `monoScratch` / `SpeakerCleanupEngine`'s downmix scratch for the same
/// pattern applied to a different buffer role). Kept `private` (file-scope) so it doesn't pollute
/// `Core`'s internal namespace — nothing outside this file needs to name it.
private final class SpikeRecorder {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let writtenBox: UnsafeMutablePointer<Int32>

    init(capacityFrames: Int) {
        capacity = max(1, capacityFrames)
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        writtenBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        writtenBox.pointee = 0
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
        writtenBox.deallocate()
    }

    /// Tap-callback thread: append up to `count` frames, allocation-free. Drops the tail once full.
    func append(_ src: UnsafePointer<Float>, count: Int) {
        let written = Int(writtenBox.pointee)
        guard written < capacity, count > 0 else { return }
        let n = min(count, capacity - written)
        (buffer + written).update(from: src, count: n)
        writtenBox.pointee = Int32(written + n)
    }

    /// Main-thread snapshot, called only AFTER the tap producing this recorder has been removed.
    func snapshot() -> [Float] {
        Array(UnsafeBufferPointer(start: buffer, count: Int(writtenBox.pointee)))
    }

    /// Computed at snapshot time from the same counters `append`/`snapshot` already maintain.
    var status: SpikeRecorderStatus {
        let written = Int(writtenBox.pointee)
        if written == 0 { return .ranDry }
        if written >= capacity { return .overflowed }
        return .ok
    }
}

// MARK: - Real-time-safe single-shot playback source

/// Pre-allocated, single-shot (non-looping) playback source: supplies frames from a fixed buffer
/// starting at index 0, then silence once exhausted. The render callback is the sole reader/writer
/// of `readIndex`, so no synchronization is needed beyond that single-threaded confinement. Kept
/// `private` (file-scope) — see `SpikeRecorder`'s doc for why.
private final class SpikePlaybackSource {
    private let samples: UnsafeMutablePointer<Float>
    private let count: Int
    private var readIndex = 0

    init(_ src: [Float]) {
        count = src.count
        samples = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
        if count > 0 {
            src.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                samples.update(from: base, count: count)
            }
        }
    }

    deinit { samples.deallocate() }

    /// Render-thread only: fill `dst` with the next `n` frames, padding with silence once the
    /// buffer is exhausted. Allocation-free.
    func fill(_ dst: UnsafeMutablePointer<Float>, count n: Int) {
        var written = 0
        if readIndex < count {
            let remaining = count - readIndex
            let take = min(remaining, n)
            dst.update(from: samples + readIndex, count: take)
            readIndex += take
            written = take
        }
        if written < n {
            (dst + written).update(repeating: 0, count: n - written)
        }
    }
}

// MARK: - Deterministic PRNG (burst-signal generation only — not used on any realtime thread)

/// SplitMix64, a small, fast, deterministic PRNG. Used only to generate the spike's burst test
/// signal ahead of time (not in any audio callback), so results are reproducible run-to-run
/// without pulling in a dependency or reaching for `arc4random`. Kept `private` (file-scope) — see
/// `SpikeRecorder`'s doc for why.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform double in `[0, 1)`.
    mutating func nextUniformUnitInterval() -> Double {
        Double(next() >> 11) * (1.0 / Double(1 << 53))
    }
}

// MARK: - JSON results shape
//
// All Encodable, all `private` (file-scope) — see `SpikeRecorder`'s doc for why. `JSONEncoder`
// only needs generic access to `Encodable` conformance, resolved at compile time within this file,
// so `private` here doesn't interfere with encoding.

private struct SpikeResultsJSON: Encodable {
    let scenario: String
    let generatedAt: String
    let durationSec: Double
    var selfEcho: SelfEchoResult?
    var cross: CrossResult?
    var format: FormatResult?
    var pin: PinResult?
    var agc: AGCResult?
    var tap: TapResult?
    var perf: PerfResult?
    var errors: [String: String] = [:]
}

private struct SelfEchoResult: Encodable {
    let offRecordingPath: String
    let onRecordingPath: String
    let offSampleRate: Double
    let onSampleRate: Double
    /// UID of the input device actually used, or nil for "system default" (see `inputDeviceName`).
    let inputDeviceUID: String?
    /// Human-readable label for the device actually used — "system default" when none was requested.
    let inputDeviceName: String
    let offRecorderStatus: SpikeRecorderStatus
    let onRecorderStatus: SpikeRecorderStatus
    let correlationLagFramesOff: Int
    let correlationPeakOff: Float
    let correlationLagFramesOn: Int
    let correlationPeakOn: Float
    /// OFF-run ON-window RMS: the uncancelled baseline echo level.
    let baselineOnRMS: Float
    /// ON-run ON-window RMS (windowed using the OFF pass's lag): the residual echo level once VPIO
    /// is engaged.
    let residualOnRMS: Float
    /// ON-run OFF-window RMS: the floor noise level while VPIO is engaged (informational).
    let residualOffRMS: Float
    let erleDb: Float
    let residualDbfs: Float
    let verdict: String
    /// Set when the OFF-pass correlation peak is too low to trust the ERLE/verdict above.
    let warning: String?
}

private struct CrossResult: Encodable {
    let recordingPath: String
    let baselineRecordingPath: String
    let referencePath: String
    let sampleRate: Double
    let recorderStatus: SpikeRecorderStatus
    let baselineCorrelationPeak: Float
    let baselineCorrelationLagFrames: Int
    let correlationPeak: Float
    let correlationLagFrames: Int
    let echoDetected: Bool
    let baselineCaptured: Bool
    let note: String?
}

private struct FormatResult: Encodable {
    let offInputFormat: String
    let offOutputFormat: String
    let onInputFormat: String
    let onOutputFormat: String
    let onFirstTapBufferFormat: String?
}

private struct PinResult: Encodable {
    let availableInputDevices: [String]
    let targetDeviceUID: String?
    let targetDeviceName: String?
    let pinStatus: Int32
    let pinSucceededSemantically: Bool
    let recorderStatus: SpikeRecorderStatus
    let knownErrorNote: String?
}

private struct AGCResult: Encodable {
    let onRecordingPath: String
    let offRecordingPath: String
    let onDenoisedPath: String
    let offDenoisedPath: String
    let inputDeviceUID: String?
    let inputDeviceName: String
    let onRecorderStatus: SpikeRecorderStatus
    let offRecorderStatus: SpikeRecorderStatus
    let onWindowedRMSVariance: Float
    let offWindowedRMSVariance: Float
}

private struct TapResult: Encodable {
    let available: Bool
    let started: Bool
    let telemetrySamples: [Float]
    let note: String?
}

private struct PerfResult: Encodable {
    let cpuUserSecondsDelta: Double
    let cpuSystemSecondsDelta: Double
    let engineStartWallMs: Double
    let loopLatencyMsEstimate: Double
    let recorderStatus: SpikeRecorderStatus
}
