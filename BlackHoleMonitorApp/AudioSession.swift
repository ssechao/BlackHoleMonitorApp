import Foundation
import AudioToolbox
import CoreAudio
import Accelerate

/// Settings read by the audio threads, published as one plain value.
struct RenderParameters {
    var gain: Float = 1.0
    var compressorEnabled = false
    var karaokeEnabled = false
    var karaokeIntensity: Float = 1.0
    /// Demucs requested *and* connected; otherwise Mid-Side is used.
    var karaokeUseAI = false
    var driftCorrectionEnabled = true
    var visualizationActive = false
}

/// One running routing session: an input AUHAL capturing from the source
/// device and an output AUHAL rendering to the destination device.
///
/// Everything touched by the render callbacks lives here and is allocated in
/// `init`. The main thread communicates only through `parameters` and the
/// per-processor mailboxes (`compressor`, `equalizer`), never by mutating
/// state the audio threads read.
final class AudioSession {
    static let preferredMaxFrames: UInt32 = 4096
    static let targetLatencyMs = 30.0
    static let maxLatencyMs = 150.0
    static let latencyStepMs = 10.0

    let channels: Int
    let inputSampleRate: Double
    let outputSampleRate: Double
    let parameters = ParameterMailbox(RenderParameters())
    let compressor: Compressor
    let equalizer: Equalizer
    let demucsBridge: DemucsBridge

    private let inputUnit: AudioUnit
    private let outputUnit: AudioUnit
    private let inputInterleaved: Bool
    private let outputInterleaved: Bool
    private let maxFrames: Int

    private let ringBuffer: RingBuffer
    private let resampler: Resampler?
    private let driftController = DriftController()
    private let karaoke: MidSideKaraoke
    private let visualizer: AudioVisualizer?

    // Preallocated scratch buffers
    private let inputBufferList: UnsafeMutableAudioBufferListPointer
    private let inputScratch: UnsafeMutablePointer<Float>       // maxFrames * channels
    private let interleaveScratch: UnsafeMutablePointer<Float>  // maxFrames * channels
    private let resampleScratch: UnsafeMutablePointer<Float>
    private let resampleCapacity: Int
    private let renderScratch: UnsafeMutablePointer<Float>      // maxFrames * channels

    // Thread-confined copies of `parameters`
    private var inputParams = RenderParameters()
    private var inputParamsVersion: UInt64 = 0
    private var inputDriftWasEnabled = true
    private var outputParams = RenderParameters()
    private var outputParamsVersion: UInt64 = 0

    private var started = false
    private var disposed = false

    init(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID,
         inputSampleRate: Double, outputSampleRate: Double,
         channels: Int, visualizationTap: VisualizationTap) throws {
        self.channels = channels
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate

        let input = try Self.makeHALUnit(isInput: true, deviceID: inputDevice, sampleRate: inputSampleRate, channels: channels)
        let output: (unit: AudioUnit, interleaved: Bool, maxFrames: Int)
        do {
            output = try Self.makeHALUnit(isInput: false, deviceID: outputDevice, sampleRate: outputSampleRate, channels: channels)
        } catch {
            AudioComponentInstanceDispose(input.unit)
            throw error
        }
        inputUnit = input.unit
        outputUnit = output.unit
        inputInterleaved = input.interleaved
        outputInterleaved = output.interleaved
        maxFrames = max(input.maxFrames, output.maxFrames, Int(Self.preferredMaxFrames))

        let framesPerMs = outputSampleRate / 1000
        ringBuffer = RingBuffer(
            capacityFrames: Int(outputSampleRate * 2),
            channels: channels,
            targetFrames: Int(Self.targetLatencyMs * framesPerMs),
            maxTargetFrames: Int(Self.maxLatencyMs * framesPerMs),
            latencyStepFrames: Int(Self.latencyStepMs * framesPerMs)
        )
        // Same nominal rate: no resampling (drift is then handled by the
        // ring buffer's emergency drop and priming).
        if inputSampleRate != outputSampleRate {
            let r = Resampler(inputSampleRate: inputSampleRate, outputSampleRate: outputSampleRate, channels: channels)
            resampler = r
            resampleCapacity = r.maxOutputFrames(forInputFrames: maxFrames)
        } else {
            resampler = nil
            resampleCapacity = 0
        }

        compressor = Compressor(sampleRate: outputSampleRate, channels: channels)
        equalizer = Equalizer(sampleRate: outputSampleRate)
        karaoke = MidSideKaraoke(sampleRate: outputSampleRate)
        demucsBridge = DemucsBridge(sampleRate: outputSampleRate)
        visualizer = AudioVisualizer(sampleRate: outputSampleRate, tap: visualizationTap)

        inputBufferList = AudioBufferList.allocate(maximumBuffers: channels)
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            p.initialize(repeating: 0, count: max(count, 1))
            return p
        }
        inputScratch = buffer(maxFrames * channels)
        interleaveScratch = buffer(maxFrames * channels)
        resampleScratch = buffer(resampleCapacity * channels)
        renderScratch = buffer(maxFrames * channels)
    }

    deinit {
        stop()
        free(inputBufferList.unsafeMutablePointer)
        inputScratch.deallocate()
        interleaveScratch.deallocate()
        resampleScratch.deallocate()
        renderScratch.deallocate()
    }

    // MARK: - Lifecycle (main thread)

    func start() throws {
        precondition(!started && !disposed)
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var inputCallback = AURenderCallbackStruct(inputProc: audioSessionInputCallback, inputProcRefCon: refCon)
        var outputCallback = AURenderCallbackStruct(inputProc: audioSessionOutputCallback, inputProcRefCon: refCon)
        let size = UInt32(MemoryLayout<AURenderCallbackStruct>.size)

        try check(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, size), "Set input callback")
        try check(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCallback, size), "Set output callback")
        try check(AudioUnitInitialize(inputUnit), "AudioUnitInitialize input")
        try check(AudioUnitInitialize(outputUnit), "AudioUnitInitialize output")
        started = true
        try check(AudioOutputUnitStart(inputUnit), "AudioOutputUnitStart input")
        try check(AudioOutputUnitStart(outputUnit), "AudioOutputUnitStart output")
    }

    /// Stops and disposes both units. When it returns, no callback can run anymore.
    func stop() {
        guard !disposed else { return }
        disposed = true
        for unit in [inputUnit, outputUnit] {
            if started {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
            }
            AudioComponentInstanceDispose(unit)
        }
    }

    func setDriftCorrectionEnabled(_ enabled: Bool) {
        ringBuffer.setEmergencyDropEnabled(enabled)
    }

    /// Current playback buffer target (grows after underruns).
    var currentLatencyMs: Double {
        Double(ringBuffer.targetFrames) / outputSampleRate * 1000
    }

    var underrunCount: Int { ringBuffer.underrunCount }

    // MARK: - Input thread

    fileprivate func captureInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                  _ timeStamp: UnsafePointer<AudioTimeStamp>,
                                  _ bus: UInt32, _ frameCount: UInt32) -> OSStatus {
        let frames = Int(frameCount)
        guard frames <= maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }

        if inputInterleaved {
            inputBufferList.count = 1
            inputBufferList[0] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: inputScratch
            )
        } else {
            inputBufferList.count = channels
            for channel in 0..<channels {
                inputBufferList[channel] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: inputScratch + channel * maxFrames
                )
            }
        }

        let status = AudioUnitRender(inputUnit, flags, timeStamp, bus, frameCount, inputBufferList.unsafeMutablePointer)
        guard status == noErr else { return status }

        let interleaved: UnsafeMutablePointer<Float>
        if inputInterleaved {
            interleaved = inputScratch
        } else {
            interleave(planar: inputScratch, stride: maxFrames, frames: frames, into: interleaveScratch)
            interleaved = interleaveScratch
        }

        parameters.fetch(into: &inputParams, lastVersion: &inputParamsVersion)

        if let resampler {
            var ratio = 1.0
            if inputParams.driftCorrectionEnabled {
                ratio = driftController.calculateRatio(availableFrames: ringBuffer.availableFrames,
                                                       targetFrames: ringBuffer.targetFrames)
            } else if inputDriftWasEnabled {
                driftController.reset()
            }
            inputDriftWasEnabled = inputParams.driftCorrectionEnabled

            let produced = resampler.process(input: interleaved, inputFrames: frames, ratioAdjustment: ratio,
                                             output: resampleScratch, outputCapacity: resampleCapacity)
            ringBuffer.write(resampleScratch, frames: produced)
        } else {
            ringBuffer.write(interleaved, frames: frames)
        }
        return noErr
    }

    private func interleave(planar: UnsafeMutablePointer<Float>, stride: Int, frames: Int, into out: UnsafeMutablePointer<Float>) {
        if channels == 2 {
            var split = DSPSplitComplex(realp: planar, imagp: planar + stride)
            out.withMemoryRebound(to: DSPComplex.self, capacity: frames) {
                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(frames))
            }
            return
        }
        for channel in 0..<channels {
            let source = planar + channel * stride
            for frame in 0..<frames {
                out[frame * channels + channel] = source[frame]
            }
        }
    }

    // MARK: - Output thread

    fileprivate func render(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        parameters.fetch(into: &outputParams, lastVersion: &outputParamsVersion)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let total = Int(frameCount)
        var offset = 0
        while offset < total {
            let frames = min(maxFrames, total - offset)
            renderBlock(frames: frames)
            copyToOutput(buffers, offset: offset, frames: frames)
            offset += frames
        }
    }

    private func renderBlock(frames: Int) {
        let data = renderScratch
        let p = outputParams
        ringBuffer.read(data, frames: frames)

        if p.karaokeEnabled {
            if p.karaokeUseAI {
                demucsBridge.process(data, frameCount: frames, channels: channels, intensity: p.karaokeIntensity)
            } else {
                karaoke.process(data, frameCount: frames, channels: channels, intensity: p.karaokeIntensity)
            }
        }
        if p.compressorEnabled {
            compressor.process(data, frameCount: frames)
        }
        equalizer.process(data, frameCount: frames, channels: channels)
        if p.visualizationActive {
            visualizer?.process(data, frameCount: frames, channels: channels)
        }

        let samples = frames * channels
        var gain = p.gain
        vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(samples))
        for i in 0..<samples where abs(data[i]) < 1e-15 {
            data[i] = 0
        }
    }

    private func copyToOutput(_ buffers: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) {
        let source = renderScratch
        if outputInterleaved {
            guard buffers.count > 0, let mData = buffers[0].mData else { return }
            let destChannels = max(Int(buffers[0].mNumberChannels), 1)
            let dest = mData.assumingMemoryBound(to: Float.self) + offset * destChannels
            if destChannels == channels {
                dest.update(from: source, count: frames * channels)
            } else {
                for frame in 0..<frames {
                    for channel in 0..<destChannels {
                        dest[frame * destChannels + channel] = channel < channels ? source[frame * channels + channel] : 0
                    }
                }
            }
            return
        }

        if channels == 2, buffers.count >= 2,
           let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            var split = DSPSplitComplex(realp: left + offset, imagp: right + offset)
            source.withMemoryRebound(to: DSPComplex.self, capacity: frames) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frames))
            }
            return
        }
        for channel in 0..<min(channels, buffers.count) {
            guard let dest = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frames {
                dest[offset + frame] = source[frame * channels + channel]
            }
        }
    }

    // MARK: - HAL unit creation

    private static func makeHALUnit(isInput: Bool, deviceID: AudioDeviceID, sampleRate: Double, channels: Int) throws
        -> (unit: AudioUnit, interleaved: Bool, maxFrames: Int) {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioSessionError.message("HAL output component not found")
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "AudioComponentInstanceNew")
        guard let unit = instance else { throw AudioSessionError.message("Failed to create audio unit") }

        do {
            let uint32Size = UInt32(MemoryLayout<UInt32>.size)
            var inputIO: UInt32 = isInput ? 1 : 0
            var outputIO: UInt32 = isInput ? 0 : 1
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                           &inputIO, uint32Size), "EnableIO input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                           &outputIO, uint32Size), "EnableIO output")

            var device = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "Set current device")

            var maxFrames = preferredMaxFrames
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, uint32Size)
            var maxFramesSize = uint32Size
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxFramesSize)

            let floatSize = UInt32(MemoryLayout<Float>.size)
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
                mBytesPerPacket: floatSize * UInt32(channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: floatSize * UInt32(channels),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: floatSize * 8,
                mReserved: 0
            )
            // Input: client side is the output scope of bus 1. Output: input scope of bus 0.
            let scope = isInput ? kAudioUnitScope_Output : kAudioUnitScope_Input
            let element: AudioUnitElement = isInput ? 1 : 0
            let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

            if AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, formatSize) == noErr {
                return (unit, true, Int(maxFrames))
            }
            format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
                | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
            format.mBytesPerPacket = floatSize
            format.mBytesPerFrame = floatSize
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, formatSize),
                      isInput ? "Set input stream format" : "Set output stream format")
            return (unit, false, Int(maxFrames))
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }
}

enum AudioSessionError: LocalizedError {
    case message(String)
    case status(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .status(let what, let status): return "\(what) failed: \(status)"
        }
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw AudioSessionError.status(what, status) }
}

// MARK: - C callbacks

private func audioSessionInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let session = Unmanaged<AudioSession>.fromOpaque(inRefCon).takeUnretainedValue()
    return session.captureInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}

private func audioSessionOutputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let session = Unmanaged<AudioSession>.fromOpaque(inRefCon).takeUnretainedValue()
    session.render(ioData, frameCount: inNumberFrames)
    return noErr
}
