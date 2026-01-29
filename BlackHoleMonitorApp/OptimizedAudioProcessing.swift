import Foundation
import Accelerate

// MARK: - Anti-Denormal Protection
// Denormal numbers (very small floats ~1e-38) cause massive CPU slowdowns
// Adding a tiny DC offset prevents this

@inline(__always)
func flushDenormals(_ value: Float) -> Float {
    // If value is in denormal range, flush to zero
    return abs(value) < 1e-15 ? 0.0 : value
}

@inline(__always)
func antiDenormal(_ value: Float) -> Float {
    // Add tiny noise to prevent denormals (inaudible)
    return value + 1e-25
}

// Flush denormals in a buffer using vDSP
func flushDenormalsInBuffer(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
    // Threshold small values to zero
    var threshold: Float = 1e-15
    var zero: Float = 0.0
    vDSP_vthres(buffer, 1, &threshold, buffer, 1, vDSP_Length(count))
    
    // Also clamp negative tiny values
    for i in 0..<count {
        if abs(buffer[i]) < 1e-15 {
            buffer[i] = 0.0
        }
    }
}

// MARK: - Smooth Drift Controller
// Replaces the abrupt drift correction with smooth, hysteresis-based control

final class SmoothDriftController {
    
    // Configuration
    private let threshold: Int = 512          // Frames before correction kicks in (was 64)
    private let hysteresisZone: Int = 256     // Dead zone to prevent oscillation
    private let maxAdjustment: Double = 0.001 // Max ±0.1% adjustment
    private let smoothingFactor: Double = 0.1 // How fast ratio changes (0.1 = slow, 1.0 = instant)
    
    // State
    private var currentRatio: Double = 1.0
    private var targetRatio: Double = 1.0
    
    private let sampleRate: Double
    
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }
    
    func getThreshold() -> Int {
        return threshold
    }
    
    /// Calculate the resample ratio adjustment based on buffer state
    /// - Parameters:
    ///   - availableFrames: Current frames in buffer
    ///   - targetFrames: Desired frames in buffer (latency target)
    /// - Returns: Ratio adjustment (1.0 = no change, >1.0 = speed up, <1.0 = slow down)
    func calculateRatio(availableFrames: Int, targetFrames: Int) -> Double {
        let diff = availableFrames - targetFrames
        
        // Inside hysteresis zone: gradually return to 1.0
        if abs(diff) < hysteresisZone {
            targetRatio = 1.0
        }
        // Buffer too full: speed up (produce more output samples per input)
        else if diff > threshold {
            // Proportional control: larger diff = larger adjustment
            let overflow = Double(diff - threshold) / Double(targetFrames)
            let adjustment = min(overflow * 0.0005, maxAdjustment)
            targetRatio = 1.0 + adjustment
        }
        // Buffer too empty: slow down
        else if diff < -threshold {
            let underflow = Double(-diff - threshold) / Double(targetFrames)
            let adjustment = min(underflow * 0.0005, maxAdjustment)
            targetRatio = 1.0 - adjustment
        }
        
        // Smooth transition to target ratio (exponential smoothing)
        currentRatio = currentRatio + smoothingFactor * (targetRatio - currentRatio)
        
        // Clamp to reasonable range
        currentRatio = max(0.999, min(1.001, currentRatio))
        
        return currentRatio
    }
    
    /// Reset the controller state
    func reset() {
        currentRatio = 1.0
        targetRatio = 1.0
    }
}

// MARK: - Optimized Compressor
// Pre-allocates all buffers to avoid allocation in audio thread

final class OptimizedCompressor {
    
    // Pre-allocated buffers (sized for max expected buffer)
    private var absBuffer: [Float]
    private let maxFrames: Int = 4096
    private let channels: Int
    
    // Parameters (cached for audio thread safety)
    private var thresholdLinear: Float = 0.1
    private var ratio: Float = 4.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var makeupGainLinear: Float = 1.0
    
    // State
    private var envelope: Float = 0.0
    private let sampleRate: Float
    
    // Processing configuration
    private let blockSize: Int = 32  // Larger blocks = less overhead
    
    init(sampleRate: Double, channels: Int) {
        self.sampleRate = Float(sampleRate)
        self.channels = channels
        
        // Pre-allocate buffer for maximum expected size
        self.absBuffer = [Float](repeating: 0, count: maxFrames * channels)
    }
    
    func hasPreAllocatedBuffer() -> Bool {
        return absBuffer.count >= blockSize * channels
    }
    
    /// Update compressor parameters (call from main thread)
    func setParameters(threshold: Float, ratio: Float, attack: Float, release: Float, makeupGain: Float) {
        thresholdLinear = powf(10.0, threshold / 20.0)
        self.ratio = ratio
        attackCoeff = expf(-1.0 / (attack * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (release * 0.001 * sampleRate))
        makeupGainLinear = powf(10.0, makeupGain / 20.0)
    }
    
    func getCurrentEnvelope() -> Float {
        return envelope
    }
    
    /// Process audio with compression (audio thread safe - no allocations)
    func process(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        let totalSamples = frameCount * channels
        
        // Fast path: just apply makeup gain if threshold is very low
        if thresholdLinear < 0.00001 {
            var gain = makeupGainLinear
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(totalSamples))
            return
        }
        
        let exponent = 1.0 - 1.0 / ratio
        var frameIndex = 0
        
        while frameIndex < frameCount {
            let framesThisBlock = min(blockSize, frameCount - frameIndex)
            let sampleOffset = frameIndex * channels
            let samplesThisBlock = framesThisBlock * channels
            
            // Use pre-allocated buffer (no allocation!)
            // Get absolute values
            vDSP_vabs(data.advanced(by: sampleOffset), 1, &absBuffer, 1, vDSP_Length(samplesThisBlock))
            
            // Find peak in block
            var blockPeak: Float = 0.0
            vDSP_maxv(absBuffer, 1, &blockPeak, vDSP_Length(samplesThisBlock))
            
            // Envelope follower with smoothed attack/release
            // Add anti-denormal protection to prevent CPU spikes on quiet audio
            if blockPeak > envelope {
                envelope = attackCoeff * envelope + (1.0 - attackCoeff) * blockPeak
            } else {
                envelope = releaseCoeff * envelope + (1.0 - releaseCoeff) * blockPeak
            }
            // Flush denormals - critical for preventing crackles on quiet passages
            envelope = flushDenormals(envelope)
            
            // Calculate gain reduction
            var gainReduction: Float = makeupGainLinear
            if envelope > thresholdLinear {
                let overRatio = envelope / thresholdLinear
                gainReduction = fastPow(1.0 / overRatio, exponent) * makeupGainLinear
            }
            
            // Apply gain to block using vDSP (vectorized)
            vDSP_vsmul(data.advanced(by: sampleOffset), 1, &gainReduction, 
                      data.advanced(by: sampleOffset), 1, vDSP_Length(samplesThisBlock))
            
            frameIndex += framesThisBlock
        }
    }
    
    /// Fast power approximation for audio
    @inline(__always)
    private func fastPow(_ base: Float, _ exp: Float) -> Float {
        if base > 0.5 && base < 2.0 && abs(exp) < 2.0 {
            // Taylor approximation for values near 1
            let x = base - 1.0
            return 1.0 + exp * x + 0.5 * exp * (exp - 1.0) * x * x
        }
        return powf(base, exp)
    }
    
    /// Reset compressor state
    func reset() {
        envelope = 0.0
    }
}

// MARK: - Optimized Ring Buffer
// Enhanced version with better drift handling

final class OptimizedRingBuffer {
    private var buffer: [Float]
    private let capacityFrames: Int
    private let channels: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var availableFrames: Int = 0
    private var lock = os_unfair_lock()
    
    // Drift controller
    private let driftController: SmoothDriftController
    private var driftCorrectionEnabled: Bool = true
    
    // Target latency
    private let targetFrames: Int
    private let maxFrames: Int
    
    // Anti-pop smoothing
    private var lastSample: [Float]
    private var wasUnderrun: Bool = false
    
    init(capacityFrames: Int, channels: Int, targetLatencyMs: Double = 30, sampleRate: Double = 44100) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.buffer = Array(repeating: 0.0, count: capacityFrames * channels)
        self.lastSample = Array(repeating: 0.0, count: channels)
        
        self.targetFrames = Int(targetLatencyMs * 0.001 * sampleRate)
        self.maxFrames = targetFrames * 4
        
        self.driftController = SmoothDriftController(sampleRate: sampleRate)
    }
    
    func setDriftCorrectionEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&lock)
        driftCorrectionEnabled = enabled
        if !enabled {
            driftController.reset()
        }
        os_unfair_lock_unlock(&lock)
    }
    
    /// Get the current drift ratio adjustment
    func getDriftRatio() -> Double {
        os_unfair_lock_lock(&lock)
        let ratio = driftCorrectionEnabled 
            ? driftController.calculateRatio(availableFrames: availableFrames, targetFrames: targetFrames)
            : 1.0
        os_unfair_lock_unlock(&lock)
        return ratio
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
    
    func write(_ data: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        
        // If buffer is way too full, drop frames to catch up (emergency only)
        if driftCorrectionEnabled && availableFrames > maxFrames {
            let framesToDrop = availableFrames - targetFrames
            readIndex = (readIndex + framesToDrop * channels) % buffer.count
            availableFrames -= framesToDrop
        }
        
        for frame in 0..<frames {
            if availableFrames == capacityFrames {
                // Buffer full, overwrite oldest
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
        let fadeLength = min(32, framesToRead)
        
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
                        let fadeRatio = Float(f) / Float(fadeOutLength)
                        outData[outOffset + channel] = lastSample[channel] * (1.0 - fadeRatio)
                    } else {
                        outData[outOffset + channel] = 0.0
                    }
                }
            }
            
            for channel in 0..<channels {
                lastSample[channel] = 0.0
            }
        }
        
        os_unfair_lock_unlock(&lock)
    }
    
    func reset() {
        os_unfair_lock_lock(&lock)
        writeIndex = 0
        readIndex = 0
        availableFrames = 0
        wasUnderrun = false
        driftController.reset()
        for i in 0..<channels {
            lastSample[i] = 0.0
        }
        os_unfair_lock_unlock(&lock)
    }
}
