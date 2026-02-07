import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock

// MARK: - CoreAudio Device Change Callback (C function)

private func deviceChangeCallback(
    objectID: AudioObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let audioManager = Unmanaged<AudioManager>.fromOpaque(clientData).takeUnretainedValue()
    
    // Handle on main thread to avoid threading issues
    DispatchQueue.main.async {
        audioManager.handleDeviceChange()
    }
    
    return noErr
}

// MARK: - Biquad Filter (EQ)

struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    var z1: Float = 0
    var z2: Float = 0
    
    // Anti-denormal constant (inaudible DC offset)
    private static let antiDenormal: Float = 1e-25

    mutating func process(_ x: Float) -> Float {
        // Add tiny DC offset to prevent denormals (causes crackles on quiet audio)
        let input = x + Biquad.antiDenormal
        let y = b0 * input + z1
        z1 = b1 * input - a1 * y + z2
        z2 = b2 * input - a2 * y
        
        // Flush denormals in state variables
        if abs(z1) < 1e-15 { z1 = 0 }
        if abs(z2) < 1e-15 { z2 = 0 }
        
        return y
    }
}

// MARK: - High-Quality vDSP Resampler

final class VDSPResampler {
    private let inputSampleRate: Double
    private let outputSampleRate: Double
    private let channels: Int
    private let baseRatio: Double  // outputRate / inputRate
    
    // History buffer for interpolation (per channel)
    private var history: [[Float]]  // Last 4 samples per channel for cubic interpolation
    private var fractionalPosition: Double = 0.0
    
    init(inputSampleRate: Double, outputSampleRate: Double, channels: Int) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.channels = channels
        self.baseRatio = outputSampleRate / inputSampleRate
        self.history = Array(repeating: Array(repeating: 0.0, count: 4), count: channels)
    }
    
    /// Resample audio data with optional ratio adjustment for drift correction
    /// - Parameters:
    ///   - input: Interleaved input samples
    ///   - inputFrames: Number of input frames
    ///   - ratioAdjustment: Fine-tuning multiplier (e.g., 1.0005 for +0.05%)
    /// - Returns: Interleaved output samples
    func resample(input: UnsafePointer<Float>, inputFrames: Int, ratioAdjustment: Double = 1.0) -> [Float] {
        let effectiveRatio = baseRatio * ratioAdjustment
        let outputFrames = Int(ceil(Double(inputFrames) * effectiveRatio))
        
        var output = [Float](repeating: 0.0, count: outputFrames * channels)
        
        // Step through output samples
        let inputStep = 1.0 / effectiveRatio  // How much we advance in input per output sample
        
        for outFrame in 0..<outputFrames {
            let inputPosition = fractionalPosition + Double(outFrame) * inputStep
            let inputIndex = Int(inputPosition)
            let frac = Float(inputPosition - Double(inputIndex))
            
            for channel in 0..<channels {
                // Get 4 samples for cubic interpolation: s0, s1, s2, s3
                // We interpolate between s1 and s2
                let s0 = getSample(input: input, inputFrames: inputFrames, frame: inputIndex - 1, channel: channel)
                let s1 = getSample(input: input, inputFrames: inputFrames, frame: inputIndex, channel: channel)
                let s2 = getSample(input: input, inputFrames: inputFrames, frame: inputIndex + 1, channel: channel)
                let s3 = getSample(input: input, inputFrames: inputFrames, frame: inputIndex + 2, channel: channel)
                
                // Cubic Hermite interpolation (smooth, no overshoot)
                let interpolated = cubicHermite(s0: s0, s1: s1, s2: s2, s3: s3, t: frac)
                output[outFrame * channels + channel] = interpolated
            }
        }
        
        // Update fractional position for next call (maintain continuity)
        let totalInputConsumed = Double(outputFrames) * inputStep
        let wholeFramesConsumed = Int(totalInputConsumed)
        fractionalPosition = totalInputConsumed - Double(wholeFramesConsumed)
        
        // Update history with last samples from input
        for channel in 0..<channels {
            for i in 0..<4 {
                let frame = inputFrames - 4 + i
                if frame >= 0 {
                    history[channel][i] = input[frame * channels + channel]
                }
            }
        }
        
        return output
    }
    
    /// Get sample with bounds checking, using history for negative indices
    @inline(__always)
    private func getSample(input: UnsafePointer<Float>, inputFrames: Int, frame: Int, channel: Int) -> Float {
        if frame < 0 {
            // Use history buffer
            let historyIndex = 4 + frame  // frame is negative, so this gives 0-3
            if historyIndex >= 0 && historyIndex < 4 {
                return history[channel][historyIndex]
            }
            return 0.0
        } else if frame >= inputFrames {
            // Beyond input, use last sample (will be corrected next buffer)
            return input[(inputFrames - 1) * channels + channel]
        }
        return input[frame * channels + channel]
    }
    
    /// Cubic Hermite interpolation - smooth with no overshoot
    @inline(__always)
    private func cubicHermite(s0: Float, s1: Float, s2: Float, s3: Float, t: Float) -> Float {
        // Hermite basis functions
        let t2 = t * t
        let t3 = t2 * t
        
        // Catmull-Rom spline (variant of Hermite)
        let a = -0.5 * s0 + 1.5 * s1 - 1.5 * s2 + 0.5 * s3
        let b = s0 - 2.5 * s1 + 2.0 * s2 - 0.5 * s3
        let c = -0.5 * s0 + 0.5 * s2
        let d = s1
        
        return a * t3 + b * t2 + c * t + d
    }
    
    /// Reset the resampler state (call when restarting audio)
    func reset() {
        fractionalPosition = 0.0
        for channel in 0..<channels {
            for i in 0..<4 {
                history[channel][i] = 0.0
            }
        }
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isInput: Bool
    let isOutput: Bool
}

/// Separate ObservableObject for visualization data.
/// This prevents spectrum/oscilloscope updates from triggering
/// a full re-render of the entire MenuBarView (which contains
/// pickers, sliders, toggles, etc.).
final class VisualizationData: ObservableObject {
    @Published var spectrumBands: [Float] = Array(repeating: 0.0, count: 16)
    @Published var oscilloscopeSamples: [Float] = Array(repeating: 0.0, count: 256)
}

final class AudioManager: ObservableObject {
    static let shared = AudioManager()

    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID = 0
    @Published var selectedOutputID: AudioDeviceID = 0
    @Published var volume: Float = 1.0 {
        didSet {
            applyVolume(volume)
            saveSettings()
        }
    }
    var previousVolume: Float = 1.0  // For mute toggle
    @Published var isRunning = false
    @Published var inputSampleRateDisplay: Int = 0
    @Published var outputSampleRateDisplay: Int = 0
    @Published var sampleRateMismatch: Bool = false  // Warning when resampling is needed
    
    // Visualization data is in a SEPARATE ObservableObject to avoid
    // triggering full MenuBarView re-renders on every frame update.
    // MenuBarView observes AudioManager for controls, SpectrumView observes visualizationData.
    let visualizationData = VisualizationData()
    
    // UI update throttling (20 fps - sufficient for visualization, saves CPU)
    private var lastUIUpdateTime: CFAbsoluteTime = 0
    private let uiUpdateInterval: CFAbsoluteTime = 1.0 / 20.0  // 20 fps
    
    // Whether visualization updates are active (disabled when popover is closed)
    var visualizationActive: Bool = true
    
    // Equalizer (8 bands, -12dB to +12dB)
    @Published var eqBands: [Float] = Array(repeating: 0.0, count: 8) {
        didSet { updateEQFilters() }
    }
    private let eqFrequencies: [Float] = [60, 120, 250, 500, 1000, 2000, 4000, 8000]
    private var eqFiltersLeft: [Biquad] = []
    private var eqFiltersRight: [Biquad] = []
    
    private var fftSetup: vDSP_DFT_Setup?
    private var spectrumBuffer: [Float] = []
    private let spectrumBufferSize = 1024  // FFT size
    private var spectrumDecay: [Float] = Array(repeating: 0.0, count: 16)
    private let decayRate: Float = 0.85  // How fast bars fall

    // Compressor settings
    @Published var compressorEnabled: Bool = false {
        didSet { saveSettings(); updateCompressorCache() }
    }
    @Published var compressorThreshold: Float = -20.0 {  // dB
        didSet { saveSettings(); updateCompressorCache() }
    }
    @Published var compressorRatio: Float = 4.0 {  // ratio :1
        didSet { saveSettings(); updateCompressorCache() }
    }
    @Published var compressorAttack: Float = 10.0 {  // ms
        didSet { saveSettings(); updateCompressorCache() }
    }
    @Published var compressorRelease: Float = 100.0 {  // ms
        didSet { saveSettings(); updateCompressorCache() }
    }
    @Published var compressorMakeupGain: Float = 0.0 {  // dB
        didSet { saveSettings(); updateCompressorCache() }
    }
    
    // Drift correction via resampling (optional, only when compressor is active)
    @Published var driftCorrectionEnabled: Bool = true {
        didSet { 
            cachedDriftCorrectionEnabled = driftCorrectionEnabled
            ringBuffer?.setDriftCorrectionEnabled(driftCorrectionEnabled)
            saveSettings() 
        }
    }
    
    // Karaoke mode (vocal removal via center channel cancellation)
    @Published var karaokeEnabled: Bool = false {
        didSet {
            cachedKaraokeEnabled = karaokeEnabled
            saveSettings()
        }
    }
    @Published var karaokeIntensity: Float = 1.0 {  // 0.0 = normal, 1.0 = full vocal removal
        didSet {
            cachedKaraokeIntensity = karaokeIntensity
            saveSettings()
        }
    }
    @Published var karaokeUseAI: Bool = false {  // Use AI model instead of Mid-Side
        didSet {
            cachedKaraokeUseAI = karaokeUseAI
            saveSettings()
        }
    }
    
    // AI Vocal Separator
    private var vocalSeparatorAI: VocalSeparatorAI?
    @Published var karaokeAIAvailable: Bool = false

    var inputUnit: AudioUnit?
    var outputUnit: AudioUnit?
    private var ringBuffer: RingBuffer?
    private var resampler: VDSPResampler?  // High-quality vDSP resampler
    private var inputSampleRate: Double = 48000
    private var outputSampleRate: Double = 48000
    private var channels: Int = 2
    private var currentVolume: Float = 1.0
    private var inputInterleaved = true
    private var outputInterleaved = true
    private var resampleRatioAdjustment: Double = 1.0  // 0.9995 à 1.0005 pour drift correction

    // Optimized audio processing (TDD-tested)
    private var optimizedCompressor: OptimizedCompressor?
    private var driftController: SmoothDriftController?
    
    // Compressor state (legacy - kept for compatibility)
    private var compressorEnvelope: Float = 0.0
    
    // Cached compressor parameters (updated from main thread, read from audio thread)
    private var cachedCompressorEnabled: Bool = false
    private var cachedThresholdLinear: Float = 0.1
    private var cachedRatio: Float = 4.0
    private var cachedAttackCoeff: Float = 0.0
    private var cachedReleaseCoeff: Float = 0.0
    private var cachedMakeupGainLinear: Float = 1.0
    private var cachedDriftCorrectionEnabled: Bool = true
    
    // Cached karaoke parameters
    private var cachedKaraokeEnabled: Bool = false
    private var cachedKaraokeIntensity: Float = 1.0
    private var cachedKaraokeUseAI: Bool = false

    // Device change monitoring
    private var deviceChangeListenerAdded = false
    private var wasRunningBeforeDeviceLoss = false
    private var lastSelectedOutputID: AudioDeviceID = 0
    private var lastSelectedOutputName: String = ""  // Match by name since USB ID changes on reconnect
    
    private init() {
        refreshDevices()
        loadSavedSettings()
        updateCompressorCache()
        setupFFT()
        updateEQFilters()
        initializeAIVocalSeparator()
        initializeOptimizedProcessing()
        setupDeviceChangeListener()
    }
    
    private func initializeOptimizedProcessing() {
        // Initialize drift controller
        driftController = SmoothDriftController(sampleRate: outputSampleRate > 0 ? outputSampleRate : 44100)
        
        // Initialize optimized compressor
        optimizedCompressor = OptimizedCompressor(sampleRate: outputSampleRate > 0 ? outputSampleRate : 44100, channels: channels)
        updateOptimizedCompressorParams()
        
        log("Optimized audio processing initialized")
    }
    
    private func updateOptimizedCompressorParams() {
        optimizedCompressor?.setParameters(
            threshold: compressorThreshold,
            ratio: compressorRatio,
            attack: compressorAttack,
            release: compressorRelease,
            makeupGain: compressorMakeupGain
        )
    }
    
    private func initializeAIVocalSeparator() {
        vocalSeparatorAI = VocalSeparatorAI()
        vocalSeparatorAI?.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                self?.karaokeAIAvailable = connected
                if connected {
                    self?.log("Demucs AI connected successfully")
                } else {
                    self?.log("Demucs AI disconnected")
                }
            }
        }
        karaokeAIAvailable = vocalSeparatorAI?.isAvailable ?? false
        log("AI Vocal Separator initializing...")
    }
    
    private func setupFFT() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(spectrumBufferSize), .FORWARD)
        spectrumBuffer = Array(repeating: 0.0, count: spectrumBufferSize)
    }
    
    // MARK: - Device Change Monitoring
    
    private func setupDeviceChangeListener() {
        guard !deviceChangeListenerAdded else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        if status == noErr {
            deviceChangeListenerAdded = true
            log("Device change listener installed")
        } else {
            log("Failed to install device change listener: \(status)")
        }
    }
    
    func handleDeviceChange() {
        log("Audio device change detected")
        
        let previousOutputID = selectedOutputID
        let previousOutputName = outputDevices.first { $0.id == previousOutputID }?.name ?? lastSelectedOutputName
        
        refreshDevices()
        
        // Check if our output device is still available (by ID)
        let outputStillAvailable = outputDevices.contains { $0.id == previousOutputID }
        
        if isRunning && !outputStillAvailable {
            // Output device was disconnected while running
            log("Output device '\(previousOutputName)' (ID:\(previousOutputID)) disconnected - stopping audio")
            wasRunningBeforeDeviceLoss = true
            lastSelectedOutputID = previousOutputID
            lastSelectedOutputName = previousOutputName
            stop()
        } else if !isRunning && wasRunningBeforeDeviceLoss && !lastSelectedOutputName.isEmpty {
            // Check if our device came back - match by NAME since USB ID changes on reconnect
            if let reconnectedDevice = outputDevices.first(where: { $0.name == lastSelectedOutputName }) {
                log("Output device '\(lastSelectedOutputName)' reconnected with new ID:\(reconnectedDevice.id) - restarting audio")
                selectedOutputID = reconnectedDevice.id
                wasRunningBeforeDeviceLoss = false
                lastSelectedOutputName = ""
                
                // Delay restart to let the device fully initialize
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.start()
                }
            }
        }
        
        // Notify UI to refresh device lists
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func refreshDevices() {
        let devices = getAllDevices()
        inputDevices = devices.filter { $0.isInput }
        outputDevices = devices.filter { $0.isOutput }

        if selectedInputID == 0, let blackhole = inputDevices.first(where: { $0.name.lowercased().contains("blackhole") }) {
            selectedInputID = blackhole.id
        } else if selectedInputID == 0, let first = inputDevices.first {
            selectedInputID = first.id
        }

        if selectedOutputID == 0, let first = outputDevices.first(where: { !$0.name.lowercased().contains("blackhole") }) {
            selectedOutputID = first.id
        } else if selectedOutputID == 0, let first = outputDevices.first {
            selectedOutputID = first.id
        }
    }

    private func log(_ message: String) {
        let logFile = "/tmp/bhm_debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
            }
        }
    }
    
    func start() {
        log("start() called")
        guard !isRunning else { 
            log("Already running")
            return 
        }

        do {
            log("Starting... Input ID: \(selectedInputID), Output ID: \(selectedOutputID)")
            
            guard let inRate = getDeviceSampleRate(selectedInputID),
                  let outRate = getDeviceSampleRate(selectedOutputID) else {
                log("Failed to get sample rates for input:\(selectedInputID) output:\(selectedOutputID)")
                return
            }
            
            log("Sample rates: \(inRate) -> \(outRate)")

            inputSampleRate = inRate
            outputSampleRate = outRate
            inputSampleRateDisplay = Int(inRate)
            outputSampleRateDisplay = Int(outRate)
            sampleRateMismatch = (inRate != outRate)  // Set warning flag

            // Ring buffer with 30ms target latency and drift correction
            ringBuffer = RingBuffer(
                capacityFrames: Int(outputSampleRate * 2),
                channels: channels,
                targetLatencyMs: 30,
                sampleRate: outputSampleRate
            )

            let inputConfig = try createHALUnit(isInput: true, deviceID: selectedInputID, sampleRate: inputSampleRate, channels: channels)
            let outputConfig = try createHALUnit(isInput: false, deviceID: selectedOutputID, sampleRate: outputSampleRate, channels: channels)

            inputUnit = inputConfig.unit
            outputUnit = outputConfig.unit
            inputInterleaved = inputConfig.interleaved
            outputInterleaved = outputConfig.interleaved

            // Create vDSP resampler if sample rates differ
            if inputSampleRate != outputSampleRate {
                resampler = VDSPResampler(
                    inputSampleRate: inputSampleRate,
                    outputSampleRate: outputSampleRate,
                    channels: channels
                )
            } else {
                resampler = nil
            }
            
            // Update compressor cache with correct sample rate
            updateCompressorCache()
            
            // Reinitialize optimized processing with correct sample rate
            driftController = SmoothDriftController(sampleRate: outputSampleRate)
            optimizedCompressor = OptimizedCompressor(sampleRate: outputSampleRate, channels: channels)
            updateOptimizedCompressorParams()

            guard let inputUnit = inputUnit, let outputUnit = outputUnit else {
                throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio units not initialized"])
            }

            let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

            var inputCallback = AURenderCallbackStruct(
                inputProc: audioInputCallback,
                inputProcRefCon: refCon
            )
            var outputCallback = AURenderCallbackStruct(
                inputProc: audioOutputCallback,
                inputProcRefCon: refCon
            )

            try check(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set input callback")
            try check(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set output callback")

            try check(AudioUnitInitialize(inputUnit), "AudioUnitInitialize input")
            try check(AudioUnitInitialize(outputUnit), "AudioUnitInitialize output")
            try check(AudioOutputUnitStart(inputUnit), "AudioOutputUnitStart input")
            try check(AudioOutputUnitStart(outputUnit), "AudioOutputUnitStart output")

            isRunning = true
            saveSettings()
            log("Audio routing started successfully")
        } catch {
            log("Failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let unit = inputUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }

        inputUnit = nil
        outputUnit = nil
        resampler = nil
        isRunning = false
    }

    func applyVolume(_ value: Float) {
        let clamped = max(0.0, min(value, 1.0))
        // Apply exponential curve to match human hearing (loudness is logarithmic)
        // Using x^3 curve: slider at 50% → gain 0.125 → -18dB (perceived as ~half volume)
        // This feels natural: small slider movements at top = small volume changes,
        // large slider movements at bottom = gradual fade to silence
        if clamped <= 0 {
            currentVolume = 0
        } else {
            currentVolume = clamped * clamped * clamped
        }
    }

    // MARK: - Audio Processing

    func processInput(unit: AudioUnit, frames: UInt32) -> OSStatus {
        guard let ringBuffer = ringBuffer else { return -1 }

        let byteSize = Int(frames) * channels * MemoryLayout<Float>.size
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: MemoryLayout<Float>.alignment)
        defer { data.deallocate() }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(inputInterleaved ? channels : 1),
                mDataByteSize: UInt32(inputInterleaved ? byteSize : Int(frames) * MemoryLayout<Float>.size),
                mData: data
            )
        )

        var timeStamp = AudioTimeStamp()
        let status = AudioUnitRender(unit, nil, &timeStamp, 1, frames, &bufferList)
        if status != noErr {
            return status
        }

        var interleaved: [Float]
        let framesInt = Int(frames)

        if inputInterleaved {
            let floatData = data.assumingMemoryBound(to: Float.self)
            interleaved = Array(UnsafeBufferPointer(start: floatData, count: framesInt * channels))
        } else {
            interleaved = [Float](repeating: 0.0, count: framesInt * channels)
            for channel in 0..<channels {
                let channelData = data.advanced(by: channel * framesInt * MemoryLayout<Float>.size).assumingMemoryBound(to: Float.self)
                for frame in 0..<framesInt {
                    interleaved[frame * channels + channel] = channelData[frame]
                }
            }
        }

        if let resampler = resampler {
            // Use vDSP resampler with drift correction
            updateResampleRatio()
            
            let resampled = interleaved.withUnsafeBufferPointer { ptr -> [Float] in
                return resampler.resample(
                    input: ptr.baseAddress!,
                    inputFrames: framesInt,
                    ratioAdjustment: resampleRatioAdjustment
                )
            }
            
            let outFrames = resampled.count / channels
            resampled.withUnsafeBufferPointer { ptr in
                ringBuffer.write(ptr.baseAddress!, frames: outFrames)
            }
        } else {
            // No resampling needed - same sample rate
            interleaved.withUnsafeBufferPointer { bufferPointer in
                ringBuffer.write(bufferPointer.baseAddress!, frames: framesInt)
            }
        }

        return noErr
    }

    func processOutput(ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        guard let ringBuffer = ringBuffer else { return }

        let gain = currentVolume
        let framesInt = Int(frames)
        let compEnabled = cachedCompressorEnabled  // Use cached value, not @Published
        let karaokeEnabled = cachedKaraokeEnabled

        if outputInterleaved {
            guard let data = ioData.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return }

            ringBuffer.read(data, frames: framesInt)

            // Apply karaoke (vocal removal) first
            if karaokeEnabled {
                applyKaraoke(data, frameCount: framesInt)
            }

            // Apply compressor if enabled
            if compEnabled {
                applyCompression(data, frameCount: framesInt)
            }
            
            // Apply EQ
            applyEQ(data, frameCount: framesInt)
            
            // Analyze spectrum for visualization
            analyzeSpectrum(data, frameCount: framesInt)
            updateOscilloscope(data, frameCount: framesInt)

            // Apply volume using Accelerate
            var volume = gain
            vDSP_vsmul(data, 1, &volume, data, 1, vDSP_Length(framesInt * channels))
            
            // Final denormal flush - prevents crackles on quiet passages
            for i in 0..<(framesInt * channels) {
                if abs(data[i]) < 1e-15 {
                    data[i] = 0
                }
            }
            return
        }

        let bufferListPointer = UnsafeMutableAudioBufferListPointer(ioData)
        var interleaved = [Float](repeating: 0.0, count: framesInt * channels)
        interleaved.withUnsafeMutableBufferPointer { ptr in
            ringBuffer.read(ptr.baseAddress!, frames: framesInt)

            // Apply karaoke (vocal removal) first
            if karaokeEnabled {
                applyKaraoke(ptr.baseAddress!, frameCount: framesInt)
            }

            // Apply compressor if enabled
            if compEnabled {
                applyCompression(ptr.baseAddress!, frameCount: framesInt)
            }
            
            // Apply EQ
            applyEQ(ptr.baseAddress!, frameCount: framesInt)
            
            // Analyze spectrum for visualization
            analyzeSpectrum(ptr.baseAddress!, frameCount: framesInt)
            updateOscilloscope(ptr.baseAddress!, frameCount: framesInt)
        }

        for channel in 0..<min(channels, bufferListPointer.count) {
            guard let data = bufferListPointer[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<framesInt {
                data[frame] = interleaved[frame * channels + channel] * gain
            }
        }
    }

    // MARK: - Compressor
    
    func updateCompressorCache() {
        let sampleRate = Float(outputSampleRate > 0 ? outputSampleRate : 44100)
        
        cachedCompressorEnabled = compressorEnabled
        cachedThresholdLinear = powf(10.0, compressorThreshold / 20.0)
        cachedRatio = compressorRatio
        cachedAttackCoeff = expf(-1.0 / (compressorAttack * 0.001 * sampleRate))
        cachedReleaseCoeff = expf(-1.0 / (compressorRelease * 0.001 * sampleRate))
        cachedMakeupGainLinear = powf(10.0, compressorMakeupGain / 20.0)
        
        // Update optimized compressor as well
        updateOptimizedCompressorParams()
    }
    
    private func updateResampleRatio() {
        // Skip drift correction if disabled (use cached value for thread safety)
        guard cachedDriftCorrectionEnabled else {
            resampleRatioAdjustment = 1.0
            return
        }
        
        guard let ringBuffer = ringBuffer else { return }
        
        let available = ringBuffer.getAvailableFrames()
        let target = ringBuffer.getTargetFrames()
        
        // Use optimized drift controller with smooth transitions
        if let controller = driftController {
            resampleRatioAdjustment = controller.calculateRatio(availableFrames: available, targetFrames: target)
        } else {
            // Fallback to legacy behavior (shouldn't happen)
            let diff = available - target
            if diff > 512 {
                resampleRatioAdjustment = 1.0005
            } else if diff < -512 {
                resampleRatioAdjustment = 0.9995
            } else {
                resampleRatioAdjustment = 1.0
            }
        }
    }
    
    private func updateEQFilters() {
        let sampleRate = Float(outputSampleRate > 0 ? outputSampleRate : 44100)
        
        // Initialize filters if needed
        if eqFiltersLeft.count != eqFrequencies.count {
            eqFiltersLeft = Array(repeating: Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0), count: eqFrequencies.count)
            eqFiltersRight = Array(repeating: Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0), count: eqFrequencies.count)
        }
        
        for i in 0..<eqFrequencies.count {
            let gainDB = eqBands.indices.contains(i) ? eqBands[i] : 0
            let freq = eqFrequencies[i]
            let q: Float = 1.0
            
            let (b0, b1, b2, a1, a2) = makePeakingEQ(freq: freq, q: q, gainDB: gainDB, sampleRate: sampleRate)
            eqFiltersLeft[i] = Biquad(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
            eqFiltersRight[i] = Biquad(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
        }
    }
    
    private func makePeakingEQ(freq: Float, q: Float, gainDB: Float, sampleRate: Float) -> (Float, Float, Float, Float, Float) {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosw0 = cos(w0)
        
        let b0 = 1 + alpha * A
        let b1 = -2 * cosw0
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1 = -2 * cosw0
        let a2 = 1 - alpha / A
        
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    private func applyCompression(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Use optimized compressor (no allocations in audio thread)
        if let compressor = optimizedCompressor {
            compressor.process(data, frameCount: frameCount)
            return
        }
        
        // Fallback to legacy implementation (shouldn't be needed)
        let thresholdLinear = cachedThresholdLinear
        let ratio = cachedRatio
        let attackCoeff = cachedAttackCoeff
        let releaseCoeff = cachedReleaseCoeff
        let makeupGainLinear = cachedMakeupGainLinear
        
        let totalSamples = frameCount * channels
        
        if thresholdLinear < 0.00001 {
            var gain = makeupGainLinear
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(totalSamples))
            return
        }

        let blockSize = 32  // Larger blocks for better performance
        let exponent = 1.0 - 1.0 / ratio
        var frameIndex = 0
        
        while frameIndex < frameCount {
            let framesThisBlock = min(blockSize, frameCount - frameIndex)
            let sampleOffset = frameIndex * channels
            
            var blockPeak: Float = 0.0
            for i in 0..<(framesThisBlock * channels) {
                blockPeak = max(blockPeak, abs(data[sampleOffset + i]))
            }
            
            if blockPeak > compressorEnvelope {
                compressorEnvelope = attackCoeff * compressorEnvelope + (1.0 - attackCoeff) * blockPeak
            } else {
                compressorEnvelope = releaseCoeff * compressorEnvelope + (1.0 - releaseCoeff) * blockPeak
            }
            
            var gainReduction: Float = makeupGainLinear
            if compressorEnvelope > thresholdLinear {
                let overRatio = compressorEnvelope / thresholdLinear
                gainReduction = fastPow(1.0 / overRatio, exponent) * makeupGainLinear
            }
            
            vDSP_vsmul(data.advanced(by: sampleOffset), 1, &gainReduction, data.advanced(by: sampleOffset), 1, vDSP_Length(framesThisBlock * channels))
            
            frameIndex += framesThisBlock
        }
    }
    
    private func applyEQ(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard eqFiltersLeft.count == eqFrequencies.count else { return }
        
        for frame in 0..<frameCount {
            let baseIndex = frame * channels
            var left = data[baseIndex]
            var right = channels > 1 ? data[baseIndex + 1] : left
            
            for i in 0..<eqFrequencies.count {
                left = eqFiltersLeft[i].process(left)
                right = eqFiltersRight[i].process(right)
            }
            
            data[baseIndex] = left
            if channels > 1 {
                data[baseIndex + 1] = right
            }
        }
    }
    
    // MARK: - Karaoke (Vocal Removal)
    
    // Filter states for karaoke 3-band processing
    private var karaokeLPF_L: Float = 0.0   // Bass low-pass (< 120Hz)
    private var karaokeLPF_R: Float = 0.0
    private var karaokeHPF_L: Float = 0.0   // Presence high-pass (> 5kHz)
    private var karaokeHPF_R: Float = 0.0
    
    private func applyKaraoke(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Only works with stereo audio
        guard channels >= 2 else { return }
        
        let intensity = cachedKaraokeIntensity
        let useAI = cachedKaraokeUseAI
        
        // Use AI model if enabled and available
        if useAI, let aiSeparator = vocalSeparatorAI, aiSeparator.isAvailable {
            aiSeparator.process(data, frameCount: frameCount, intensity: intensity)
            return
        }
        
        // 3-band Mid-Side processing with vocal reverb removal
        //
        // Problem: Modern mixes spread vocals to the sides via reverb/delay/chorus.
        // Basic Mid-Side only removes the center, leaving vocal effects on the sides.
        //
        // Solution: Split into 3 bands and treat each differently:
        //   Bass    (< 120Hz) : preserve 100% (kick, bass guitar)
        //   Vocal   (120Hz-5kHz) : remove center strongly + attenuate sides partially
        //   Air     (> 5kHz) : light side reduction (cymbals live here too)
        
        let sr = inputSampleRate > 0 ? Float(inputSampleRate) : 48000.0
        
        // Filter coefficients (1-pole IIR)
        let bassFreq: Float = 120.0
        let airFreq: Float = 5000.0
        let alphaLow = (2.0 * Float.pi * bassFreq) / (sr + 2.0 * Float.pi * bassFreq)
        let alphaHigh = (2.0 * Float.pi * airFreq) / (sr + 2.0 * Float.pi * airFreq)
        
        var lpfL = karaokeLPF_L
        var lpfR = karaokeLPF_R
        var hpfL = karaokeHPF_L
        var hpfR = karaokeHPF_R
        
        // How much to attenuate the sides in the vocal band (catches reverb/effects)
        // 0.4 = remove 40% of the side signal in the vocal range
        let sideReduction = intensity * 0.4
        // Light side reduction in the air band (preserve cymbals)
        let airSideReduction = intensity * 0.15
        
        for frame in 0..<frameCount {
            let baseIndex = frame * channels
            let left = data[baseIndex]
            let right = data[baseIndex + 1]
            
            // Band 1: Bass (low-pass < 120Hz) — preserved untouched
            lpfL = alphaLow * left + (1.0 - alphaLow) * lpfL
            lpfR = alphaLow * right + (1.0 - alphaLow) * lpfR
            
            // Band 3: Air (low-pass to extract, then subtract for high-pass > 5kHz)
            hpfL = alphaHigh * left + (1.0 - alphaHigh) * hpfL
            hpfR = alphaHigh * right + (1.0 - alphaHigh) * hpfR
            let airL = left - hpfL  // High-pass > 5kHz
            let airR = right - hpfR
            
            // Band 2: Vocal (everything between bass and air)
            let vocalL = left - lpfL - airL
            let vocalR = right - lpfR - airR
            
            // Mid-Side on vocal band (strong center + partial side removal)
            let vocalMid = (vocalL + vocalR) * 0.5
            let vocalSide = (vocalL - vocalR) * 0.5
            let processedVocalMid = vocalMid * (1.0 - intensity)
            let processedVocalSide = vocalSide * (1.0 - sideReduction)
            
            // Mid-Side on air band (light side reduction only)
            let airMid = (airL + airR) * 0.5
            let airSide = (airL - airR) * 0.5
            let processedAirMid = airMid * (1.0 - intensity * 0.5)  // Less aggressive on air
            let processedAirSide = airSide * (1.0 - airSideReduction)
            
            // Reconstruct: bass (clean) + vocal (processed) + air (lightly processed)
            data[baseIndex]     = lpfL + (processedVocalMid + processedVocalSide) + (processedAirMid + processedAirSide)
            data[baseIndex + 1] = lpfR + (processedVocalMid - processedVocalSide) + (processedAirMid - processedAirSide)
        }
        
        karaokeLPF_L = lpfL
        karaokeLPF_R = lpfR
        karaokeHPF_L = hpfL
        karaokeHPF_R = hpfR
    }
    
    // Fast power approximation using exp/log approximation
    @inline(__always)
    private func fastPow(_ base: Float, _ exp: Float) -> Float {
        // For values close to 1, use linear approximation
        // For others, use the standard pow but it's called less frequently
        if base > 0.5 && base < 2.0 && abs(exp) < 2.0 {
            // Taylor approximation: x^a ≈ 1 + a*(x-1) for x near 1
            return 1.0 + exp * (base - 1.0) + 0.5 * exp * (exp - 1.0) * (base - 1.0) * (base - 1.0)
        }
        return powf(base, exp)
    }
    
    // MARK: - Spectrum Analyzer
    
    private func analyzeSpectrum(_ data: UnsafePointer<Float>, frameCount: Int) {
        guard let fftSetup = fftSetup else { return }
        
        // Mix stereo to mono and fill buffer
        let samplesToProcess = min(frameCount, spectrumBufferSize)
        for i in 0..<samplesToProcess {
            // Average left and right channels
            let left = data[i * channels]
            let right = channels > 1 ? data[i * channels + 1] : left
            spectrumBuffer[i] = (left + right) * 0.5
        }
        
        // Zero pad if needed
        if samplesToProcess < spectrumBufferSize {
            for i in samplesToProcess..<spectrumBufferSize {
                spectrumBuffer[i] = 0.0
            }
        }
        
        // Apply Hann window
        var window = [Float](repeating: 0.0, count: spectrumBufferSize)
        vDSP_hann_window(&window, vDSP_Length(spectrumBufferSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(spectrumBuffer, 1, window, 1, &spectrumBuffer, 1, vDSP_Length(spectrumBufferSize))
        
        // Prepare for FFT (split complex)
        var realIn = [Float](repeating: 0.0, count: spectrumBufferSize)
        var imagIn = [Float](repeating: 0.0, count: spectrumBufferSize)
        var realOut = [Float](repeating: 0.0, count: spectrumBufferSize)
        var imagOut = [Float](repeating: 0.0, count: spectrumBufferSize)
        
        realIn = spectrumBuffer
        
        // Perform FFT
        vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)
        
        // Calculate magnitude (only need first half due to symmetry)
        let halfSize = spectrumBufferSize / 2
        var magnitudes = [Float](repeating: 0.0, count: halfSize)
        
        for i in 0..<halfSize {
            magnitudes[i] = sqrtf(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }
        
        // Map to 16 bands (logarithmic frequency scale like Alpine)
        // 32Hz to 16kHz range - where actual music content exists
        // At 44.1kHz with 1024 FFT: bin = freq * 1024 / 44100
        // Bands: 32-45, 45-63, 63-90, 90-125, 125-180, 180-250, 250-355, 355-500, 500-710, 710-1k, 1k-1.4k, 1.4k-2k, 2k-4k, 4k-8k, 8k-12k, 12k-16k Hz
        let bandEdges: [Int] = [2, 3, 4, 5, 7, 10, 14, 19, 26, 37, 52, 73, 104, 185, 278, 372]
        var newBands = [Float](repeating: 0.0, count: 16)
        
        for band in 0..<16 {
            let startBin = band == 0 ? 1 : bandEdges[band - 1]
            let endBin = min(bandEdges[band], halfSize)
            
            if endBin > startBin {
                // Find max in this band (peak detection)
                var maxVal: Float = 0.0
                magnitudes.withUnsafeBufferPointer { ptr in
                    vDSP_maxv(ptr.baseAddress! + startBin, 1, &maxVal, vDSP_Length(endBin - startBin))
                }
                
                // Convert to dB and normalize
                // Range: -20dB to +40dB maps to 0.0-1.0
                let db = 20.0 * log10f(max(maxVal, 1e-10))
                let normalized = (db + 20.0) / 60.0
                newBands[band] = max(0.0, min(1.0, normalized))
            }
        }
        
        // Apply decay (smooth falling bars)
        for i in 0..<16 {
            if newBands[i] > spectrumDecay[i] {
                spectrumDecay[i] = newBands[i]
            } else {
                spectrumDecay[i] = spectrumDecay[i] * decayRate
            }
        }
        
        // Throttle UI updates to 20 fps to avoid CPU overload
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastUIUpdateTime >= uiUpdateInterval else { return }
        lastUIUpdateTime = now
        
        // Skip if visualization is disabled (popover closed)
        guard visualizationActive else { return }
        
        // Update separate visualization object (doesn't trigger MenuBarView re-render)
        let bandsToUpdate = spectrumDecay
        let vizData = visualizationData
        DispatchQueue.main.async {
            vizData.spectrumBands = bandsToUpdate
        }
    }
    
    private var lastOscilloscopeUpdateTime: CFAbsoluteTime = 0
    
    private func updateOscilloscope(_ data: UnsafePointer<Float>, frameCount: Int) {
        // Throttle oscilloscope updates to 20 fps (same as spectrum)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastOscilloscopeUpdateTime >= uiUpdateInterval else { return }
        lastOscilloscopeUpdateTime = now
        
        // Skip if visualization is disabled (popover closed)
        guard visualizationActive else { return }
        
        let targetCount = 256  // Fixed count matching VisualizationData
        
        let stride = max(1, frameCount / targetCount)
        var samples = [Float](repeating: 0.0, count: targetCount)
        
        for i in 0..<targetCount {
            let index = min(i * stride * channels, frameCount * channels - channels)
            let left = data[index]
            let right = channels > 1 ? data[index + 1] : left
            samples[i] = (left + right) * 0.5
        }
        
        let vizData = visualizationData
        DispatchQueue.main.async {
            vizData.oscilloscopeSamples = samples
        }
    }

    // MARK: - HAL Unit Creation

    private func createHALUnit(isInput: Bool, deviceID: AudioDeviceID, sampleRate: Double, channels: Int) throws -> (unit: AudioUnit, interleaved: Bool) {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "HAL output component not found"])
        }

        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
        guard let audioUnit = unit else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio unit"])
        }

        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0

        if isInput {
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)), "Enable input IO")
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size)), "Disable output IO")
        } else {
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableIO, UInt32(MemoryLayout<UInt32>.size)), "Disable input IO")
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size)), "Enable output IO")
        }

        var deviceID = deviceID
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Set current device")

        let baseFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        let interleavedFlags = baseFlags | kAudioFormatFlagIsPacked
        let deinterleavedFlags = baseFlags | kAudioFormatFlagIsNonInterleaved

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: interleavedFlags,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var setStatus: OSStatus
        if isInput {
            setStatus = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        } else {
            setStatus = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        }

        if setStatus != noErr {
            streamFormat.mFormatFlags = deinterleavedFlags
            streamFormat.mBytesPerPacket = UInt32(MemoryLayout<Float>.size)
            streamFormat.mBytesPerFrame = UInt32(MemoryLayout<Float>.size)

            if isInput {
                try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set input stream format")
            } else {
                try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set output stream format")
            }
            return (audioUnit, false)
        }

        return (audioUnit, true)
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        if status != noErr {
            throw NSError(domain: "AudioManager", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(message) failed: \(status)"])
        }
    }

    // MARK: - Device Enumeration

    private func getAllDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard let name = getDeviceName(deviceID) else { return nil }
            let isInput = hasInputChannels(deviceID)
            let isOutput = hasOutputChannels(deviceID)
            return AudioDevice(id: deviceID, name: name, isInput: isInput, isOutput: isOutput)
        }
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr else { return nil }
        return name as String
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListSize = Int(dataSize)
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: bufferListSize)
        defer { bufferList.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard getStatus == noErr else { return false }

        let bufferListPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        var totalChannels: UInt32 = 0
        for buffer in bufferListPointer {
            totalChannels += buffer.mNumberChannels
        }
        return totalChannels > 0
    }

    private func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListSize = Int(dataSize)
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: bufferListSize)
        defer { bufferList.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard getStatus == noErr else { return false }

        let bufferListPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        var totalChannels: UInt32 = 0
        for buffer in bufferListPointer {
            totalChannels += buffer.mNumberChannels
        }
        return totalChannels > 0
    }

    private func getDeviceSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Double = 0
        var dataSize = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        if status != noErr { return nil }
        return sampleRate
    }

    // MARK: - Settings Persistence

    private func saveSettings() {
        UserDefaults.standard.set(Int(selectedInputID), forKey: "selectedInputID")
        UserDefaults.standard.set(Int(selectedOutputID), forKey: "selectedOutputID")
        UserDefaults.standard.set(volume, forKey: "volume")

        // Compressor settings
        UserDefaults.standard.set(compressorEnabled, forKey: "compressorEnabled")
        UserDefaults.standard.set(compressorThreshold, forKey: "compressorThreshold")
        UserDefaults.standard.set(compressorRatio, forKey: "compressorRatio")
        UserDefaults.standard.set(compressorAttack, forKey: "compressorAttack")
        UserDefaults.standard.set(compressorRelease, forKey: "compressorRelease")
        UserDefaults.standard.set(compressorMakeupGain, forKey: "compressorMakeupGain")
        UserDefaults.standard.set(driftCorrectionEnabled, forKey: "driftCorrectionEnabled")
        
        // Karaoke settings
        UserDefaults.standard.set(karaokeEnabled, forKey: "karaokeEnabled")
        UserDefaults.standard.set(karaokeIntensity, forKey: "karaokeIntensity")
        UserDefaults.standard.set(karaokeUseAI, forKey: "karaokeUseAI")
    }

    private func loadSavedSettings() {
        if let savedInput = UserDefaults.standard.object(forKey: "selectedInputID") as? Int, savedInput > 0 {
            selectedInputID = AudioDeviceID(savedInput)
        }
        if let savedOutput = UserDefaults.standard.object(forKey: "selectedOutputID") as? Int, savedOutput > 0 {
            selectedOutputID = AudioDeviceID(savedOutput)
        }
        if let savedVolume = UserDefaults.standard.object(forKey: "volume") as? Float {
            volume = savedVolume
        }

        // Compressor settings
        compressorEnabled = UserDefaults.standard.bool(forKey: "compressorEnabled")
        if let threshold = UserDefaults.standard.object(forKey: "compressorThreshold") as? Float {
            compressorThreshold = threshold
        }
        if let ratio = UserDefaults.standard.object(forKey: "compressorRatio") as? Float {
            compressorRatio = ratio
        }
        if let attack = UserDefaults.standard.object(forKey: "compressorAttack") as? Float {
            compressorAttack = attack
        }
        if let release = UserDefaults.standard.object(forKey: "compressorRelease") as? Float {
            compressorRelease = release
        }
        if let makeupGain = UserDefaults.standard.object(forKey: "compressorMakeupGain") as? Float {
            compressorMakeupGain = makeupGain
        }
        // Default to true if not set
        if UserDefaults.standard.object(forKey: "driftCorrectionEnabled") != nil {
            driftCorrectionEnabled = UserDefaults.standard.bool(forKey: "driftCorrectionEnabled")
        } else {
            driftCorrectionEnabled = true
        }
        
        // Karaoke settings
        karaokeEnabled = UserDefaults.standard.bool(forKey: "karaokeEnabled")
        if let intensity = UserDefaults.standard.object(forKey: "karaokeIntensity") as? Float {
            karaokeIntensity = intensity
        }
        karaokeUseAI = UserDefaults.standard.bool(forKey: "karaokeUseAI")
    }
}

// MARK: - Ring Buffer with Drift Correction

final class RingBuffer {
    private var buffer: [Float]
    private let capacityFrames: Int
    private let channels: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var availableFrames: Int = 0
    private var lock = os_unfair_lock()
    
    // Drift correction (now handled by micro-resampling in AudioManager)
    private let targetFrames: Int      // Target buffer level (latency)
    private let maxFrames: Int         // Max before we start dropping
    private let minFrames: Int         // Min before we start stretching
    private var driftCorrectionEnabled: Bool = true
    
    // For smooth transitions (anti-pop)
    private var lastSample: [Float]
    private var wasUnderrun: Bool = false

    init(capacityFrames: Int, channels: Int, targetLatencyMs: Double = 30, sampleRate: Double = 44100) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.buffer = Array(repeating: 0.0, count: capacityFrames * channels)
        self.lastSample = Array(repeating: 0.0, count: channels)
        
        // Target latency in frames
        self.targetFrames = Int(targetLatencyMs * 0.001 * sampleRate)
        self.maxFrames = targetFrames * 5     // Emergency only: 5x target (~150ms)
        self.minFrames = targetFrames / 2     // Start stretching if below half target
    }
    
    func setDriftCorrectionEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&lock)
        driftCorrectionEnabled = enabled
        os_unfair_lock_unlock(&lock)
    }

    func write(_ data: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        
        // REMOVED: Aggressive frame dropping that caused audio jumps
        // The SmoothDriftController now handles drift via micro-resampling
        // Only drop frames in EXTREME emergency (buffer > 5x target = 150ms)
        let emergencyThreshold = targetFrames * 5
        if driftCorrectionEnabled && availableFrames > emergencyThreshold {
            // Drop gradually: only 64 frames at a time to avoid audible glitch
            let framesToDrop = min(64, availableFrames - targetFrames)
            readIndex = (readIndex + framesToDrop * channels) % buffer.count
            availableFrames -= framesToDrop
        }
        
        for frame in 0..<frames {
            if availableFrames == capacityFrames {
                // Buffer full, overwrite oldest (always needed to prevent overflow)
                readIndex = (readIndex + channels) % buffer.count
                availableFrames -= 1
            }

            let frameOffset = frame * channels
            for channel in 0..<channels {
                buffer[writeIndex] = data[frameOffset + channel]
                writeIndex = (writeIndex + 1) % buffer.count
            }
            availableFrames += 1
        }
        os_unfair_lock_unlock(&lock)
    }

    func read(_ outData: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        
        let framesToRead = min(frames, availableFrames)
        let fadeLength = min(32, framesToRead)  // Crossfade length for smooth transitions
        
        // If recovering from underrun, apply fade-in from last known sample
        let needsFadeIn = wasUnderrun && framesToRead > 0
        wasUnderrun = false

        for frame in 0..<framesToRead {
            let outOffset = frame * channels
            for channel in 0..<channels {
                var sample = buffer[readIndex]
                
                // Fade-in from lastSample if recovering from underrun
                if needsFadeIn && frame < fadeLength {
                    let fadeRatio = Float(frame) / Float(fadeLength)
                    sample = lastSample[channel] * (1.0 - fadeRatio) + sample * fadeRatio
                }
                
                outData[outOffset + channel] = sample
                readIndex = (readIndex + 1) % buffer.count
            }
            availableFrames -= 1
        }
        
        // Store last sample for potential fade
        if framesToRead > 0 {
            let lastOffset = (framesToRead - 1) * channels
            for channel in 0..<channels {
                lastSample[channel] = outData[lastOffset + channel]
            }
        }

        // Fill remaining with fade-out to silence (underrun case)
        if framesToRead < frames {
            wasUnderrun = true
            let remainingFrames = frames - framesToRead
            let fadeOutLength = min(32, remainingFrames)
            
            for f in 0..<remainingFrames {
                let outOffset = (framesToRead + f) * channels
                for channel in 0..<channels {
                    if f < fadeOutLength {
                        // Fade out from last sample to silence
                        let fadeRatio = Float(f) / Float(fadeOutLength)
                        outData[outOffset + channel] = lastSample[channel] * (1.0 - fadeRatio)
                    } else {
                        outData[outOffset + channel] = 0.0
                    }
                }
            }
            
            // Update lastSample to zero after fade-out
            for channel in 0..<channels {
                lastSample[channel] = 0.0
            }
        }

        os_unfair_lock_unlock(&lock)
    }
    
    func getAvailableFrames() -> Int {
        os_unfair_lock_lock(&lock)
        let frames = availableFrames
        os_unfair_lock_unlock(&lock)
        return frames
    }
    
    func getTargetFrames() -> Int {
        return targetFrames
    }
}

// MARK: - Audio Callbacks

func audioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let manager = Unmanaged<AudioManager>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = manager.inputUnit else { return -1 }
    return manager.processInput(unit: unit, frames: inNumberFrames)
}

func audioOutputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let manager = Unmanaged<AudioManager>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioData = ioData else { return noErr }
    manager.processOutput(ioData: ioData, frames: inNumberFrames)
    return noErr
}
