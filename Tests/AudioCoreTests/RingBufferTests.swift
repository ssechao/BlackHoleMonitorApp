import XCTest
@testable import AudioCore

final class RingBufferTests: XCTestCase {
    func testWrapAroundPreservesOrder() {
        let buffer = RingBuffer(capacityFrames: 100, channels: 2)
        var out = [Float](repeating: 0, count: 40 * 2)
        var next = 0
        var expected = 0
        for _ in 0..<20 {
            let input = TestSignals.ramp(frames: 37, channels: 2, start: next)
            input.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 37) }
            next += 37
            let n = out.withUnsafeMutableBufferPointer { buffer.readAvailable(into: $0.baseAddress!, maxFrames: 40) }
            for frame in 0..<n {
                XCTAssertEqual(out[frame * 2], Float(expected))
                XCTAssertEqual(out[frame * 2 + 1], Float(expected) + 0.25)
                expected += 1
            }
        }
    }

    func testOverflowDropsOldestFrames() {
        let buffer = RingBuffer(capacityFrames: 10, channels: 1)
        let input = TestSignals.ramp(frames: 25, channels: 1)
        input.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 25) }
        XCTAssertEqual(buffer.availableFrames, 10)
        var out = [Float](repeating: 0, count: 10)
        _ = out.withUnsafeMutableBufferPointer { buffer.readAvailable(into: $0.baseAddress!, maxFrames: 10) }
        XCTAssertEqual(out, (15..<25).map(Float.init))
    }

    func testPlaybackWaitsUntilPrimed() {
        let buffer = RingBuffer(capacityFrames: 1000, channels: 1, targetFrames: 100)
        let ones = [Float](repeating: 1, count: 50)
        var out = [Float](repeating: 9, count: 32)

        ones.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 50) }
        let got = out.withUnsafeMutableBufferPointer { buffer.read($0.baseAddress!, frames: 32) }
        XCTAssertEqual(got, 0, "Must stay silent below the target")
        XCTAssertEqual(out, [Float](repeating: 0, count: 32))
        XCTAssertEqual(buffer.availableFrames, 50)

        ones.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 50) }
        let got2 = out.withUnsafeMutableBufferPointer { buffer.read($0.baseAddress!, frames: 32) }
        XCTAssertEqual(got2, 32)
    }

    func testUnderrunFadesOutAndRaisesLatency() {
        let buffer = RingBuffer(capacityFrames: 10_000, channels: 1, targetFrames: 100,
                                maxTargetFrames: 150, latencyStepFrames: 30)
        let ones = [Float](repeating: 1, count: 200)
        ones.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 200) }

        var out = [Float](repeating: 0, count: 400)
        let got = out.withUnsafeMutableBufferPointer { buffer.read($0.baseAddress!, frames: 400) }
        XCTAssertEqual(got, 200)
        XCTAssertEqual(buffer.underrunCount, 1)
        XCTAssertEqual(buffer.targetFrames, 130)

        // Fade-out right after the data, then silence: no hard step to zero
        XCTAssertEqual(out[199], 1)
        XCTAssertLessThan(abs(out[200] - out[199]), 0.05)
        XCTAssertEqual(out[200 + RingBuffer.fadeFrames], 0)

        // Second underrun is capped at maxTargetFrames
        ones.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 200) }
        _ = out.withUnsafeMutableBufferPointer { buffer.read($0.baseAddress!, frames: 400) }
        ones.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 200) }
        _ = out.withUnsafeMutableBufferPointer { buffer.read($0.baseAddress!, frames: 400) }
        XCTAssertEqual(buffer.targetFrames, 150)
    }

    func testResumeFadesIn() {
        let buffer = RingBuffer(capacityFrames: 1000, channels: 1)
        let ones = [Float](repeating: 1, count: 128)
        ones.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 128) }
        var out = [Float](repeating: 0, count: 128)
        _ = out.withUnsafeMutableBufferPointer { buffer.read($0.baseAddress!, frames: 128) }
        XCTAssertEqual(out[0], 0)
        XCTAssertLessThan(out[RingBuffer.fadeFrames / 2], 1)
        XCTAssertEqual(out[RingBuffer.fadeFrames], 1)
    }

    func testUnderrunKeepsTargetWhenStepIsZero() {
        let buffer = RingBuffer(capacityFrames: 10_000, channels: 1, targetFrames: 100,
                                maxTargetFrames: 150, latencyStepFrames: 0)
        let ones = [Float](repeating: 1, count: 200)
        ones.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 200) }
        var out = [Float](repeating: 0, count: 400)
        _ = out.withUnsafeMutableBufferPointer { buffer.read($0.baseAddress!, frames: 400) }
        XCTAssertEqual(buffer.underrunCount, 1)
        XCTAssertEqual(buffer.targetFrames, 100)
    }

    func testEmergencyDropOnlyWhenEnabled() {
        let buffer = RingBuffer(capacityFrames: 10_000, channels: 1, targetFrames: 100)
        let data = [Float](repeating: 1, count: 600)
        data.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 600) }
        data.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 1) }
        XCTAssertEqual(buffer.availableFrames, 601)

        buffer.setEmergencyDropEnabled(true)
        data.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 1) }
        XCTAssertEqual(buffer.availableFrames, 601 - 64 + 1)
    }

    func testConcurrentProducerConsumerKeepsOrder() {
        let buffer = RingBuffer(capacityFrames: 1 << 16, channels: 1)
        let total = 200_000
        let done = expectation(description: "producer")
        DispatchQueue.global().async {
            var next = 0
            while next < total {
                let n = min(256, total - next)
                let chunk = (next..<next + n).map(Float.init)
                chunk.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: n) }
                next += n
                if buffer.availableFrames > 30_000 { usleep(100) }
            }
            done.fulfill()
        }
        var expected = 0
        var out = [Float](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(10)
        while expected < total && Date() < deadline {
            let n = out.withUnsafeMutableBufferPointer { buffer.readAvailable(into: $0.baseAddress!, maxFrames: 512) }
            for i in 0..<n {
                XCTAssertEqual(out[i], Float(expected))
                expected += 1
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(expected, total)
    }
}
