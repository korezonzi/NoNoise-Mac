import Foundation
import AVFoundation
import AVFAudio
import Combine
import AudioToolbox
import CoreAudio
import Accelerate

public class AudioModel: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Published State for UI.
    // Defaults ON so NoNoise Mac is actively cancelling noise on first launch.
    @Published public var isAIEnabled: Bool = true {
        didSet {
        }
    }
    @Published public var inputDevices: [AVCaptureDevice] = [] // Changed to AVCaptureDevice
    @Published public var selectedInputDeviceID: String = "" { // IDs are Strings in AVCapture
        didSet {
             setupCaptureSession()
        }
    }
    @Published public var errorMessage: String?
    @Published public var inputLevel: Float = 0.0
    @Published public var activeOutputDeviceName: String = "Unknown"
    @Published public var permissionStatus: String = "Unknown"
    
    // Output Selection
    @Published public var outputDevices: [DeviceStruct] = []
    @Published public var selectedOutputDeviceID: AudioObjectID = 0 {
        didSet {
             setupPlaybackEngine()
        }
    }
    
    @Published public var isPlayingTestTone: Bool = false {
        didSet {
            // No action needed, source node checks this flag
        }
    }
    
    @Published public var outputGainValue: Float = 1.0 {
        didSet {
             dspEngine.outputGain = outputGainValue
             onKnobChanged()
        }
    }

    // Preset + suppression intensity (persisted to UserDefaults under mv.*).
    @Published public var selectedPreset: VoicePreset = .meeting {
        didSet {
            guard !isApplyingPreset else { return }
            applyPreset(selectedPreset)   // no-op for .custom (keeps current knobs)
            applyVoiceChain()             // reconfigure voice chain for the new preset
            persistSettings()             // persist the selection itself, incl. a direct .custom pick
        }
    }

    @Published public var suppressionStrength: Float = 1.0 {
        didSet {
            dspEngine.suppressionStrength = suppressionStrength
            onKnobChanged()
        }
    }

    @Published public var attenuationLimitDb: Float = VoicePreset.maxAttenuationDb {
        didSet {
            dspEngine.attenuationLimitDb = attenuationLimitDb
            onKnobChanged()
        }
    }

    /// Master on/off for the post-DSP voice-polish chain. Effective enabled state
    /// is `voicePolishEnabled && selectedPreset.voiceChain.enabled` (see
    /// `applyVoiceChain`). Guarded like the knobs so `loadSettings` can restore it
    /// without re-persisting or reconfiguring mid-load.
    @Published public var voicePolishEnabled: Bool = true {
        didSet {
            guard !isApplyingPreset else { return }
            applyVoiceChain()
            persistSettings()
        }
    }

    private var isApplyingPreset = false

    private enum PrefKey {
        static let preset = "mv.preset"
        static let strength = "mv.suppressionStrength"
        static let atten = "mv.attenuationLimitDb"
        static let gain = "mv.outputGain"
        static let voicePolish = "mv.voicePolish"
    }

    public struct DeviceStruct: Identifiable {
        public let id: AudioObjectID
        public let name: String
    }
    
    // Capture (Input)
    private let captureSession = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let processingQueue = DispatchQueue(label: "audio.processing.queue", qos: .userInteractive)
    
    // Playback (Output)
    private let engine = AVAudioEngine()
    private var playbackSourceNode: AVAudioSourceNode! 
    private var outputNode: AVAudioOutputNode { engine.outputNode }
    private var mainMixer: AVAudioMixerNode { engine.mainMixerNode }
    
    // Buffering
    private let ringBuffer = RingBuffer(capacity: 48000 * 5)
    
    // Processing Modules
    // Processing Modules
    private let dspEngine = DeepFilterNetDSP()
    private let voiceChain = VoiceChain()
    
    public override init() {
        super.init()
        
        let bufferRef = ringBuffer
        let dsp = dspEngine
        let chain = voiceChain
        
        playbackSourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frameCount)
            
            // 1. Test Tone
            if let self = self, self.isPlayingTestTone {
                 for i in 0..<count {
                     data[i] = Float.random(in: -0.1...0.1) 
                 }
                 return noErr
            }
            
            // 2. Latency
            let latencyTarget = 2400
            let available = bufferRef.count
            if available > (latencyTarget + count) {
                bufferRef.drop(available - latencyTarget)
            }
            
            // 3. Read
            // DSP Engine needs contiguous flow. If we underflow, we feed silence.
            if !bufferRef.read(into: data, count: count) {
                AudioUtils.shared.fillSilence(data, count: count)
                return noErr
            }
            
            // 4. Processing
            
            // Gain (Boost Mic)
            var gain: Float = 1.0
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(frameCount))
            
            if let self = self, self.isAIEnabled {
                // DSP STFT Pipeline, then voice-polish chain (no-op when disabled).
                dsp.process(input: data, count: count, output: data)
                chain.process(data, count: count)
            }
            
            return noErr
        }
        
        checkPermissions()
        fetchInputDevices()
        fetchOutputDevices()
        setupCaptureSession()
        setupPlaybackEngine()
        loadSettings()
    }

    // MARK: - Presets & suppression knobs

    /// Apply a preset's parameters to the live knobs. No-op for `.custom`.
    /// `isApplyingPreset` suppresses the knob `didSet`s from flipping the preset
    /// back to `.custom` while we apply it.
    private func applyPreset(_ preset: VoicePreset) {
        guard let p = preset.parameters else { return }  // .custom keeps current knobs
        let previously = isApplyingPreset
        isApplyingPreset = true
        suppressionStrength = p.suppressionStrength
        attenuationLimitDb = p.attenuationLimitDb
        outputGainValue = p.outputGain
        isApplyingPreset = previously
        // Persistence is the caller's responsibility (selectedPreset.didSet), so a
        // direct .custom selection — which no-ops here — is still persisted.
    }

    /// Configure the voice chain from the active preset, gated by the master
    /// toggle. Runs on the main thread (recomputes filter coefficients); the
    /// render thread only reads coefficients and runs scalar math.
    private func applyVoiceChain() {
        var s = selectedPreset.voiceChain
        s.enabled = s.enabled && voicePolishEnabled
        voiceChain.configure(s)
    }

    /// Called from any knob `didSet`. A manual change outside `applyPreset`
    /// switches the active preset to `.custom` and persists.
    private func onKnobChanged() {
        guard !isApplyingPreset else { return }
        if selectedPreset != .custom {
            isApplyingPreset = true
            selectedPreset = .custom
            isApplyingPreset = false
            applyVoiceChain()   // Custom has its own balanced chain; configure once on transition
        }
        persistSettings()
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(selectedPreset.rawValue, forKey: PrefKey.preset)
        d.set(suppressionStrength, forKey: PrefKey.strength)
        d.set(attenuationLimitDb, forKey: PrefKey.atten)
        d.set(outputGainValue, forKey: PrefKey.gain)
        d.set(voicePolishEnabled, forKey: PrefKey.voicePolish)
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: PrefKey.preset),
              let preset = VoicePreset(rawValue: raw) else {
            // First launch: keep defaults (Meeting) and push them to the DSP.
            applyPreset(.meeting)
            applyVoiceChain()
            return
        }
        // Load stored knob values (used as-is for .custom; overwritten below for
        // non-custom presets where the preset is the source of truth).
        isApplyingPreset = true
        suppressionStrength = d.object(forKey: PrefKey.strength) != nil ? d.float(forKey: PrefKey.strength) : 1.0
        attenuationLimitDb = d.object(forKey: PrefKey.atten) != nil ? d.float(forKey: PrefKey.atten) : VoicePreset.maxAttenuationDb
        outputGainValue = d.object(forKey: PrefKey.gain) != nil ? d.float(forKey: PrefKey.gain) : 1.0
        // Restore the master toggle inside the guard so its didSet doesn't
        // re-persist or reconfigure mid-load (default ON when absent).
        voicePolishEnabled = d.object(forKey: PrefKey.voicePolish) as? Bool ?? true
        selectedPreset = preset
        isApplyingPreset = false
        if let p = preset.parameters {  // non-custom: preset defines the values
            isApplyingPreset = true
            suppressionStrength = p.suppressionStrength
            attenuationLimitDb = p.attenuationLimitDb
            outputGainValue = p.outputGain
            isApplyingPreset = false
        }
        // Single explicit configure from the final restored state.
        applyVoiceChain()
    }
    
    func fetchOutputDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        
        var newDevs: [DeviceStruct] = []
        
        for id in deviceIDs {
            // Check Output Channels
            let scope = kAudioObjectPropertyScopeOutput
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: 0)
            var size: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
            if size > 0 {
                var nameSize = UInt32(MemoryLayout<CFString?>.size)
                var namePtr: Unmanaged<CFString>?
                var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &namePtr)
                if let cf = namePtr?.takeRetainedValue() {
                    newDevs.append(DeviceStruct(id: id, name: cf as String))
                }
            }
        }
        
        DispatchQueue.main.async {
            self.outputDevices = newDevs
            // Default to BlackHole if exists
            if let bh = newDevs.first(where: { $0.name.contains("BlackHole") }) {
                self.selectedOutputDeviceID = bh.id
            } else if let first = newDevs.first {
                self.selectedOutputDeviceID = first.id
            }
        }
    }
    
    // ... input methods ...
    
    func setupPlaybackEngine() {
        engine.stop()
        engine.reset()
        
        // Output Device
        if selectedOutputDeviceID != 0 {
             var deviceID = selectedOutputDeviceID
             let size = UInt32(MemoryLayout<AudioObjectID>.size)
             AudioUnitSetProperty(outputNode.audioUnit!,
                                  kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global,
                                  0,
                                  &deviceID,
                                  size)
             
             // Update Name
             if let dev = outputDevices.first(where: { $0.id == selectedOutputDeviceID }) {
                 DispatchQueue.main.async { self.activeOutputDeviceName = dev.name }
             }
        }

        // Attach Source
        engine.attach(playbackSourceNode)
        
        // Connect
        engine.connect(playbackSourceNode, to: mainMixer, format: AudioUtils.shared.processingFormat)
        engine.connect(mainMixer, to: outputNode, format: nil)
        
        do {
            try engine.start()
        } catch {
            print("Engine Error: \(error)")
        }
    }
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permissionStatus = "Authorized"
        case .denied: permissionStatus = "Denied"
        case .restricted: permissionStatus = "Restricted"
        case .notDetermined:
            permissionStatus = "Not Determined"
            AVCaptureDevice.requestAccess(for: .audio) { g in
                DispatchQueue.main.async { self.permissionStatus = g ? "Authorized" : "Denied" }
            }
        @unknown default: permissionStatus = "Unknown"
        }
    }
    
    func fetchInputDevices() {
        // AVCaptureDeviceDiscovery
        let types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone, .externalUnknown] // .externalUnknown covers USB mics usually
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
        // Note: AVCaptureDevice doesn't easily show "Loopback" devices like BlackHole.
        // But for "Microphone" input, that is what we want.
        
        var devs = session.devices
        // Sort: Built-in first?
        devs.sort { $0.localizedName < $1.localizedName }
        
        DispatchQueue.main.async {
            self.inputDevices = devs
            if let defaultDev = AVCaptureDevice.default(for: .audio) {
                 self.selectedInputDeviceID = defaultDev.uniqueID
            } else if let first = devs.first {
                self.selectedInputDeviceID = first.uniqueID
            }
        }
    }
    
    func setupCaptureSession() {
        captureSession.stopRunning()
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        
        do {
            guard let device = AVCaptureDevice(uniqueID: selectedInputDeviceID) else {
                print("Device not found: \(selectedInputDeviceID)")
                captureSession.commitConfiguration()
                return
            }
            
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            if captureSession.canAddOutput(captureOutput) {
                captureSession.addOutput(captureOutput)
                captureOutput.setSampleBufferDelegate(self, queue: processingQueue)
            }
            
        } catch {
            print("Capture Setup Error: \(error)")
        }
        
        captureSession.commitConfiguration()
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }

    
    private var PermissionCheckOnce = false
    
    // Converter State
    private var inputConverter: AVAudioConverter?
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var inputBuffer48k: AVAudioPCMBuffer?
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Converter state persists for continuous stream. No reset needed.
        
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        // Use AudioStreamBasicDescription to create AVAudioFormat
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        
        // 1. Determine Input Format
        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else { return }
        
        // 2. Define Target Format (48kHz, Float32, Mono)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000.0, channels: 1, interleaved: false) else { return }
        
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
        
        // 7. Write to Ring Buffer
        let convertedFrames = Int(outputBuffer.frameLength)
        
        if convertedFrames > 0, let floatData = outputBuffer.floatChannelData?[0] {
             // Metering (RMS)
             var sum: Float = 0
             // Sample every 4th visual
             for i in stride(from: 0, to: min(convertedFrames, 256), by: 4) {
                 sum += floatData[i] * floatData[i]
             }
             if convertedFrames > 0 {
                 let rms = sqrt(sum / Float(min(convertedFrames, 256)/4 + 1))
                 DispatchQueue.main.async { self.inputLevel = rms }
             }
             
             // Push 48k Float32 to RingBuffer
             _ = self.ringBuffer.write(floatData, count: convertedFrames)
        }
    }
}
