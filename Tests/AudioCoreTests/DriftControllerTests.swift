import XCTest
@testable import AudioCore

final class DriftControllerTests: XCTestCase {
    let target = 1323  // ~30 ms at 44.1 kHz

    func testRatioChangesSmoothly() {
        let controller = DriftController()
        var previous = 1.0
        for _ in 0..<50 {
            let ratio = controller.calculateRatio(availableFrames: target * 3, targetFrames: target)
            XCTAssertLessThan(abs(ratio - previous), 0.0002)
            previous = ratio
        }
    }

    func testHysteresisKeepsRatioAtOne() {
        let controller = DriftController()
        for available in [target + 100, target - 100, target + 200, target - 200] {
            XCTAssertEqual(controller.calculateRatio(availableFrames: available, targetFrames: target), 1.0, accuracy: 1e-4)
        }
    }

    /// Ratio multiplies the produced output frames: a full buffer needs FEWER frames.
    /// (The previous implementation had this sign inverted.)
    func testFullBufferProducesFewerFrames() {
        let controller = DriftController()
        var ratio = 1.0
        for _ in 0..<50 {
            ratio = controller.calculateRatio(availableFrames: target * 3, targetFrames: target)
        }
        XCTAssertLessThan(ratio, 0.9999)
        XCTAssertGreaterThanOrEqual(ratio, 1.0 - controller.maxAdjustment)
    }

    func testEmptyBufferProducesMoreFrames() {
        let controller = DriftController()
        var ratio = 1.0
        for _ in 0..<50 {
            ratio = controller.calculateRatio(availableFrames: 0, targetFrames: target * 2)
        }
        XCTAssertGreaterThan(ratio, 1.0001)
        XCTAssertLessThanOrEqual(ratio, 1.0 + controller.maxAdjustment)
    }

    /// Closed loop: with independent device clocks (±100 ppm, typical crystals)
    /// the buffer must neither drain nor grow when drift correction drives the resampler.
    func testClosedLoopConvergesForFastConsumer() {
        runClosedLoop(consumerDrift: 1.0001)
    }

    func testClosedLoopConvergesForSlowConsumer() {
        runClosedLoop(consumerDrift: 0.9999)
    }

    private func runClosedLoop(consumerDrift: Double) {
        let resampler = Resampler(inputSampleRate: 48000, outputSampleRate: 48000 * 1.0004, channels: 1)
        let controller = DriftController()
        let ring = RingBuffer(capacityFrames: 48000, channels: 1, targetFrames: 1440)
        let input = [Float](repeating: 0.1, count: 512)
        var scratch = [Float](repeating: 0, count: resampler.maxOutputFrames(forInputFrames: 512))
        var out = [Float](repeating: 0, count: 512)
        let consumerFramesPerBlock = 512.0 * 1.0004 * consumerDrift
        var consumed = 0.0
        var levels: [Int] = []

        for block in 0..<20_000 {
            let ratio = controller.calculateRatio(availableFrames: ring.availableFrames, targetFrames: ring.targetFrames)
            let produced = input.withUnsafeBufferPointer { inPtr in
                scratch.withUnsafeMutableBufferPointer {
                    resampler.process(input: inPtr.baseAddress!, inputFrames: 512, ratioAdjustment: ratio,
                                      output: $0.baseAddress!, outputCapacity: $0.count)
                }
            }
            scratch.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: produced) }
            consumed += consumerFramesPerBlock
            let toRead = Int(consumed)
            consumed -= Double(toRead)
            if block > 10 {
                _ = out.withUnsafeMutableBufferPointer { ring.read($0.baseAddress!, frames: toRead) }
            }
            if block > 15_000 { levels.append(ring.availableFrames) }
        }
        XCTAssertEqual(ring.underrunCount, 0)
        XCTAssertLessThan(abs(levels.min()! - 1440), 1500)
        XCTAssertLessThan(abs(levels.max()! - 1440), 1500)
    }
}
