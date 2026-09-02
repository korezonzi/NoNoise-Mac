import Foundation
import AVFoundation
import AVFAudio

/// `MicCaptureBackend` built on `AVCaptureSession` + `AVCaptureAudioDataOutput` — the pre-Phase-1
/// capture pipeline moved here UNCHANGED (see AGENTS.md "Real-time audio rules": this is a pure
/// extraction, not a rewrite) so `AudioModel` can be handed a second, Voice-Processing-I/O-based
/// backend in Phase 2 without touching this one.
public final class AVCaptureMicBackend: NSObject, MicCaptureBackend, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var onAudio: ((UnsafeMutablePointer<Float>, Int) -> Void)?

    private let captureSession = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let processingQueue = DispatchQueue(label: "audio.processing.queue", qos: .userInteractive)

    // Converter state persists across calls for a continuous stream — reused, rebuilt only when the
    // input format changes (see `captureOutput(_:didOutput:from:)`).
    private var inputConverter: AVAudioConverter?
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var inputBuffer48k: AVAudioPCMBuffer?

    private var diagLoggedFirstSample = false

    /// Public so `AudioModel.init(micBackend:)` — a public API — can default to `AVCaptureMicBackend()`.
    public override init() {
        super.init()
    }

    public var isRunning: Bool { captureSession.isRunning }

    @discardableResult
    public func configure(deviceUID: String) -> Bool {
        captureSession.stopRunning()
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        var inputAttached = false
        do {
            guard let device = AVCaptureDevice(uniqueID: deviceUID) else {
                print("Device not found: \(deviceUID)")
                captureSession.commitConfiguration()
                return false
            }

            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                inputAttached = true
            }

            if captureSession.canAddOutput(captureOutput) {
                captureSession.addOutput(captureOutput)
                captureOutput.setSampleBufferDelegate(self, queue: processingQueue)
            }

        } catch {
            print("Capture Setup Error: \(error)")
        }

        captureSession.commitConfiguration()
        return inputAttached
    }

    public func start() {
        guard !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.captureSession.startRunning() }
    }

    public func stop() {
        guard captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.captureSession.stopRunning() }
    }

    deinit {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Converter state persists for continuous stream. No reset needed.
        if !diagLoggedFirstSample {
            diagLoggedFirstSample = true
            AudioModel.routeLog.info("captureOutput first sample received")
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        // Use AudioStreamBasicDescription to create AVAudioFormat
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        // 1. Determine Input Format
        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else { return }

        // 2. Define Target Format (48kHz, Float32, Mono)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioLatency.sampleRate, channels: 1, interleaved: false) else { return }

        // 3. Setup Converter if needed
        if inputConverter == nil || inputConverter?.inputFormat != inputFormat {
             print("AudioModel: Initializing Converter \(inputFormat.sampleRate) -> 48000")
             inputConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

             // Create Buffers
             let maxInputFrames = AVAudioFrameCount(4096)
             inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxInputFrames)

             let ratio = targetFormat.sampleRate / inputFormat.sampleRate
             let maxOutputFrames = AVAudioFrameCount(Double(maxInputFrames) * ratio + 5)
             inputBuffer48k = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: maxOutputFrames)
        }

        guard let converter = inputConverter,
              let inputBuffer = inputPCMBuffer,
              let outputBuffer = inputBuffer48k else { return }

        // 4. Copy Data Directly to InputPCMBuffer
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        inputBuffer.frameLength = AVAudioFrameCount(numSamples)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: inputBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            print("AudioModel Error: CMSampleBufferCopyPCMDataIntoAudioBufferList failed with \(status)")
            return
        }

        // 6. Convert
        var error: NSError? = nil

        // Input Block
        var haveFed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
           if !haveFed {
               outStatus.pointee = .haveData
               haveFed = true
               return inputBuffer
           } else {
               outStatus.pointee = .noDataNow
               return nil
           }
        }

        outputBuffer.frameLength = outputBuffer.frameCapacity
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        // 7. Hand normalized audio off to the owner (AudioModel.ingest via `onAudio`).
        let convertedFrames = Int(outputBuffer.frameLength)
        if convertedFrames > 0, let floatData = outputBuffer.floatChannelData?[0] {
            onAudio?(floatData, convertedFrames)
        }
    }
}
