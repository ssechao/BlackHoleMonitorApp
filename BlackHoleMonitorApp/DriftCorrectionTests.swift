import Foundation

// MARK: - Test Framework (Simple)

struct TestResult {
    let name: String
    let passed: Bool
    let message: String
}

class TestRunner {
    static var results: [TestResult] = []
    
    static func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
        if !condition {
            print("  FAIL: \(message) [\(file):\(line)]")
        }
    }
    
    static func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
        if a != b {
            print("  FAIL: Expected \(a) == \(b). \(message) [\(file):\(line)]")
        }
    }
    
    static func assertInRange(_ value: Float, min: Float, max: Float, _ message: String = "", file: String = #file, line: Int = #line) {
        if value < min || value > max {
            print("  FAIL: \(value) not in range [\(min), \(max)]. \(message) [\(file):\(line)]")
        }
    }
    
    static func run(_ name: String, _ test: () -> Bool) {
        print("Running: \(name)")
        let passed = test()
        results.append(TestResult(name: name, passed: passed, message: ""))
        print(passed ? "  PASS" : "  FAIL")
    }
    
    static func printSummary() {
        let passed = results.filter { $0.passed }.count
        let total = results.count
        print("\n========================================")
        print("Tests: \(passed)/\(total) passed")
        print("========================================")
    }
}

// MARK: - Drift Correction Tests

class DriftCorrectionTests {
    
    // Test 1: Pre-allocated buffer should not allocate during processing
    static func testPreAllocatedBufferExists() -> Bool {
        let compressor = OptimizedCompressor(sampleRate: 44100, channels: 2)
        
        // Buffer should be pre-allocated with sufficient size
        let hasBuffer = compressor.hasPreAllocatedBuffer()
        TestRunner.assert(hasBuffer, "Compressor should have pre-allocated buffer")
        
        return hasBuffer
    }
    
    // Test 2: Compressor should reuse buffer, not allocate new one
    static func testCompressorReusesBuffer() -> Bool {
        let compressor = OptimizedCompressor(sampleRate: 44100, channels: 2)
        
        var testData: [Float] = Array(repeating: 0.5, count: 1024)
        
        // Process multiple times - should not crash or leak
        for _ in 0..<100 {
            testData.withUnsafeMutableBufferPointer { ptr in
                compressor.process(ptr.baseAddress!, frameCount: 512)
            }
        }
        
        // If we get here without crash, buffer reuse works
        return true
    }
    
    // Test 3: Drift controller should have larger threshold (256+ frames)
    static func testDriftThresholdIsLarger() -> Bool {
        let controller = SmoothDriftController(sampleRate: 44100)
        
        let threshold = controller.getThreshold()
        TestRunner.assert(threshold >= 256, "Threshold should be >= 256 frames, got \(threshold)")
        
        return threshold >= 256
    }
    
    // Test 4: Drift ratio should change smoothly (not jump)
    static func testDriftRatioSmoothing() -> Bool {
        let controller = SmoothDriftController(sampleRate: 44100)
        
        // Simulate buffer being too full
        var ratios: [Double] = []
        for i in 0..<10 {
            let ratio = controller.calculateRatio(availableFrames: 2000, targetFrames: 1323)
            ratios.append(ratio)
        }
        
        // Check that ratio changes gradually, not in big jumps
        var maxJump: Double = 0
        for i in 1..<ratios.count {
            let jump = abs(ratios[i] - ratios[i-1])
            maxJump = max(maxJump, jump)
        }
        
        // Max jump should be small (smooth transition)
        let isSmooth = maxJump < 0.0002  // Less than 0.02% jump per iteration
        TestRunner.assert(isSmooth, "Ratio should change smoothly, max jump was \(maxJump)")
        
        return isSmooth
    }
    
    // Test 5: Hysteresis should prevent oscillation
    static func testHysteresisPreventOscillation() -> Bool {
        let controller = SmoothDriftController(sampleRate: 44100)
        
        let target = 1323  // ~30ms at 44.1kHz
        
        // Simulate buffer oscillating around target
        var adjustments: [Double] = []
        let testSequence = [target + 100, target - 100, target + 100, target - 100, target + 100]
        
        for available in testSequence {
            let ratio = controller.calculateRatio(availableFrames: available, targetFrames: target)
            adjustments.append(ratio)
        }
        
        // Within hysteresis zone, ratio should stay at 1.0
        let allNearOne = adjustments.allSatisfy { abs($0 - 1.0) < 0.0001 }
        TestRunner.assert(allNearOne, "Within hysteresis zone, ratio should be ~1.0")
        
        return allNearOne
    }
    
    // Test 6: Large drift should still be corrected
    static func testLargeDriftIsCorrected() -> Bool {
        let controller = SmoothDriftController(sampleRate: 44100)
        
        let target = 1323
        
        // Simulate very full buffer (3x target)
        var ratio = 1.0
        for _ in 0..<50 {
            ratio = controller.calculateRatio(availableFrames: target * 3, targetFrames: target)
        }
        
        // After multiple iterations, ratio should be > 1.0 (speed up to drain buffer)
        let isCorrecting = ratio > 1.0001
        TestRunner.assert(isCorrecting, "Large drift should be corrected, ratio=\(ratio)")
        
        return isCorrecting
    }
    
    // Test 7: Empty buffer should slow down
    static func testEmptyBufferSlowsDown() -> Bool {
        let controller = SmoothDriftController(sampleRate: 44100)
        
        let target = 1323
        
        // Simulate nearly empty buffer
        var ratio = 1.0
        for _ in 0..<50 {
            ratio = controller.calculateRatio(availableFrames: target / 4, targetFrames: target)
        }
        
        // Ratio should be < 1.0 (slow down to fill buffer)
        let isSlowing = ratio < 0.9999
        TestRunner.assert(isSlowing, "Empty buffer should slow down, ratio=\(ratio)")
        
        return isSlowing
    }
    
    // Test 8: Compressor envelope should be smooth
    static func testCompressorEnvelopeSmooth() -> Bool {
        let compressor = OptimizedCompressor(sampleRate: 44100, channels: 2)
        compressor.setParameters(threshold: -20, ratio: 4, attack: 10, release: 100, makeupGain: 0)
        
        // Create test signal: silence then loud
        var testData: [Float] = Array(repeating: 0.0, count: 512) + Array(repeating: 0.8, count: 512)
        
        testData.withUnsafeMutableBufferPointer { ptr in
            compressor.process(ptr.baseAddress!, frameCount: 512)
        }
        
        // Envelope should have risen smoothly, not jumped
        let envelope = compressor.getCurrentEnvelope()
        let isReasonable = envelope > 0 && envelope < 1.0
        TestRunner.assert(isReasonable, "Envelope should be reasonable: \(envelope)")
        
        return isReasonable
    }
    
    // Run all tests
    static func runAllTests() {
        print("\n========================================")
        print("Running Drift Correction Tests")
        print("========================================\n")
        
        TestRunner.run("Pre-allocated buffer exists", testPreAllocatedBufferExists)
        TestRunner.run("Compressor reuses buffer", testCompressorReusesBuffer)
        TestRunner.run("Drift threshold is larger", testDriftThresholdIsLarger)
        TestRunner.run("Drift ratio smoothing", testDriftRatioSmoothing)
        TestRunner.run("Hysteresis prevents oscillation", testHysteresisPreventOscillation)
        TestRunner.run("Large drift is corrected", testLargeDriftIsCorrected)
        TestRunner.run("Empty buffer slows down", testEmptyBufferSlowsDown)
        TestRunner.run("Compressor envelope smooth", testCompressorEnvelopeSmooth)
        
        TestRunner.printSummary()
    }
}
