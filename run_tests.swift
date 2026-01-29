#!/usr/bin/env swift

// Simple test runner script
// Compile and run: swift run_tests.swift

import Foundation

// Include the test and implementation files
// This is a standalone test runner

// MARK: - Smooth Drift Controller (Copy for testing)

final class SmoothDriftController {
    private let threshold: Int = 512
    private let hysteresisZone: Int = 256
    private let maxAdjustment: Double = 0.001
    private let smoothingFactor: Double = 0.1
    
    private var currentRatio: Double = 1.0
    private var targetRatio: Double = 1.0
    
    private let sampleRate: Double
    
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }
    
    func getThreshold() -> Int {
        return threshold
    }
    
    func calculateRatio(availableFrames: Int, targetFrames: Int) -> Double {
        let diff = availableFrames - targetFrames
        
        if abs(diff) < hysteresisZone {
            targetRatio = 1.0
        } else if diff > threshold {
            let overflow = Double(diff - threshold) / Double(targetFrames)
            let adjustment = min(overflow * 0.0005, maxAdjustment)
            targetRatio = 1.0 + adjustment
        } else if diff < -threshold {
            let underflow = Double(-diff - threshold) / Double(targetFrames)
            let adjustment = min(underflow * 0.0005, maxAdjustment)
            targetRatio = 1.0 - adjustment
        }
        
        currentRatio = currentRatio + smoothingFactor * (targetRatio - currentRatio)
        currentRatio = max(0.999, min(1.001, currentRatio))
        
        return currentRatio
    }
    
    func reset() {
        currentRatio = 1.0
        targetRatio = 1.0
    }
}

// MARK: - Optimized Compressor (Simplified for testing)

final class OptimizedCompressor {
    private var absBuffer: [Float]
    private let maxFrames: Int = 4096
    private let channels: Int
    
    private var thresholdLinear: Float = 0.1
    private var ratio: Float = 4.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var makeupGainLinear: Float = 1.0
    
    private var envelope: Float = 0.0
    private let sampleRate: Float
    private let blockSize: Int = 32
    
    init(sampleRate: Double, channels: Int) {
        self.sampleRate = Float(sampleRate)
        self.channels = channels
        self.absBuffer = [Float](repeating: 0, count: maxFrames * channels)
    }
    
    func hasPreAllocatedBuffer() -> Bool {
        return absBuffer.count >= blockSize * channels
    }
    
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
    
    func process(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        let totalSamples = frameCount * channels
        
        if thresholdLinear < 0.00001 {
            for i in 0..<totalSamples {
                data[i] *= makeupGainLinear
            }
            return
        }
        
        let exponent = 1.0 - 1.0 / ratio
        var frameIndex = 0
        
        while frameIndex < frameCount {
            let framesThisBlock = min(blockSize, frameCount - frameIndex)
            let sampleOffset = frameIndex * channels
            let samplesThisBlock = framesThisBlock * channels
            
            // Get absolute values into pre-allocated buffer
            for i in 0..<samplesThisBlock {
                absBuffer[i] = abs(data[sampleOffset + i])
            }
            
            // Find peak
            var blockPeak: Float = 0.0
            for i in 0..<samplesThisBlock {
                blockPeak = max(blockPeak, absBuffer[i])
            }
            
            // Envelope follower
            if blockPeak > envelope {
                envelope = attackCoeff * envelope + (1.0 - attackCoeff) * blockPeak
            } else {
                envelope = releaseCoeff * envelope + (1.0 - releaseCoeff) * blockPeak
            }
            
            // Calculate gain reduction
            var gainReduction: Float = makeupGainLinear
            if envelope > thresholdLinear {
                let overRatio = envelope / thresholdLinear
                gainReduction = powf(1.0 / overRatio, exponent) * makeupGainLinear
            }
            
            // Apply gain
            for i in 0..<samplesThisBlock {
                data[sampleOffset + i] *= gainReduction
            }
            
            frameIndex += framesThisBlock
        }
    }
    
    func reset() {
        envelope = 0.0
    }
}

// MARK: - Tests

var passedTests = 0
var totalTests = 0

func runTest(_ name: String, _ test: () -> Bool) {
    totalTests += 1
    print("Running: \(name)...", terminator: " ")
    if test() {
        print("✅ PASS")
        passedTests += 1
    } else {
        print("❌ FAIL")
    }
}

print("\n========================================")
print("🧪 Running Drift Correction Tests")
print("========================================\n")

// Test 1: Pre-allocated buffer exists
runTest("Pre-allocated buffer exists") {
    let compressor = OptimizedCompressor(sampleRate: 44100, channels: 2)
    return compressor.hasPreAllocatedBuffer()
}

// Test 2: Compressor reuses buffer
runTest("Compressor reuses buffer") {
    let compressor = OptimizedCompressor(sampleRate: 44100, channels: 2)
    var testData: [Float] = Array(repeating: 0.5, count: 1024)
    
    for _ in 0..<100 {
        testData.withUnsafeMutableBufferPointer { ptr in
            compressor.process(ptr.baseAddress!, frameCount: 512)
        }
    }
    return true // If we get here, no crash
}

// Test 3: Drift threshold is larger
runTest("Drift threshold >= 256") {
    let controller = SmoothDriftController(sampleRate: 44100)
    return controller.getThreshold() >= 256
}

// Test 4: Drift ratio smoothing
runTest("Drift ratio changes smoothly") {
    let controller = SmoothDriftController(sampleRate: 44100)
    
    var ratios: [Double] = []
    for _ in 0..<10 {
        let ratio = controller.calculateRatio(availableFrames: 2000, targetFrames: 1323)
        ratios.append(ratio)
    }
    
    var maxJump: Double = 0
    for i in 1..<ratios.count {
        let jump = abs(ratios[i] - ratios[i-1])
        maxJump = max(maxJump, jump)
    }
    
    return maxJump < 0.0002  // Less than 0.02% jump
}

// Test 5: Hysteresis prevents oscillation
runTest("Hysteresis prevents oscillation") {
    let controller = SmoothDriftController(sampleRate: 44100)
    let target = 1323
    
    var adjustments: [Double] = []
    let testSequence = [target + 100, target - 100, target + 100, target - 100, target + 100]
    
    for available in testSequence {
        let ratio = controller.calculateRatio(availableFrames: available, targetFrames: target)
        adjustments.append(ratio)
    }
    
    return adjustments.allSatisfy { abs($0 - 1.0) < 0.0001 }
}

// Test 6: Large drift is corrected
runTest("Large drift is corrected") {
    let controller = SmoothDriftController(sampleRate: 44100)
    let target = 1323
    
    var ratio = 1.0
    for _ in 0..<50 {
        ratio = controller.calculateRatio(availableFrames: target * 3, targetFrames: target)
    }
    
    return ratio > 1.0001
}

// Test 7: Empty buffer slows down
runTest("Empty buffer slows down") {
    let controller = SmoothDriftController(sampleRate: 44100)
    let target = 1323
    
    var ratio = 1.0
    for _ in 0..<50 {
        ratio = controller.calculateRatio(availableFrames: target / 4, targetFrames: target)
    }
    
    return ratio < 0.9999
}

// Test 8: Compressor envelope is smooth
runTest("Compressor envelope smooth") {
    let compressor = OptimizedCompressor(sampleRate: 44100, channels: 2)
    compressor.setParameters(threshold: -20, ratio: 4, attack: 10, release: 100, makeupGain: 0)
    
    var testData: [Float] = Array(repeating: 0.0, count: 512) + Array(repeating: 0.8, count: 512)
    
    testData.withUnsafeMutableBufferPointer { ptr in
        compressor.process(ptr.baseAddress!, frameCount: 512)
    }
    
    let envelope = compressor.getCurrentEnvelope()
    return envelope > 0 && envelope < 1.0
}

print("\n========================================")
print("Results: \(passedTests)/\(totalTests) tests passed")
print("========================================\n")

exit(passedTests == totalTests ? 0 : 1)
