import XCTest
@testable import AudioCore

final class ParameterMailboxTests: XCTestCase {
    struct Pair { var a: Int; var b: Int }

    func testFetchOnlyReturnsNewValues() {
        let mailbox = ParameterMailbox(Pair(a: 1, b: 2))
        var value = Pair(a: 0, b: 0)
        var version: UInt64 = 0
        XCTAssertTrue(mailbox.fetch(into: &value, lastVersion: &version))
        XCTAssertEqual(value.a, 1)
        XCTAssertFalse(mailbox.fetch(into: &value, lastVersion: &version))
        mailbox.publish(Pair(a: 5, b: 10))
        XCTAssertTrue(mailbox.fetch(into: &value, lastVersion: &version))
        XCTAssertEqual(value.b, 10)
    }

    func testIndependentReaders() {
        let mailbox = ParameterMailbox(Pair(a: 0, b: 0))
        var v1 = Pair(a: 0, b: 0), v2 = v1
        var r1: UInt64 = 0, r2: UInt64 = 0
        mailbox.publish(Pair(a: 3, b: 6))
        XCTAssertTrue(mailbox.fetch(into: &v1, lastVersion: &r1))
        XCTAssertTrue(mailbox.fetch(into: &v2, lastVersion: &r2))
        XCTAssertEqual(v1.a, 3)
        XCTAssertEqual(v2.a, 3)
    }

    func testNoTornReadsUnderContention() {
        let mailbox = ParameterMailbox(Pair(a: 0, b: 0))
        let writer = DispatchQueue(label: "writer")
        let done = expectation(description: "writer")
        writer.async {
            for i in 0..<200_000 { mailbox.publish(Pair(a: i, b: i * 2)) }
            done.fulfill()
        }
        var value = Pair(a: 0, b: 0)
        var version: UInt64 = 0
        for _ in 0..<200_000 {
            mailbox.fetch(into: &value, lastVersion: &version)
            XCTAssertEqual(value.b, value.a * 2)
        }
        wait(for: [done], timeout: 10)
    }
}

final class CompressorTests: XCTestCase {
    func testSteadyStateGainReduction() {
        let compressor = Compressor(sampleRate: 48000, channels: 2)
        compressor.setParameters(threshold: -20, ratio: 4, attack: 1, release: 100, makeupGain: 0)
        var data = [Float](repeating: 0.8, count: 48000 * 2)
        data.withUnsafeMutableBufferPointer { compressor.process($0.baseAddress!, frameCount: 48000) }
        // 0.8 is 18.06 dB over -20 dB; at 4:1 output is 4.5 dB over: 0.1 * 8^(1/4)
        XCTAssertEqual(data.last!, 0.1 * powf(8, 0.25), accuracy: 0.002)
    }

    /// The attack time must be honoured although the envelope runs per 32-frame block.
    func testAttackTimeIsInMilliseconds() {
        let sampleRate = 48000.0
        let compressor = Compressor(sampleRate: sampleRate, channels: 1)
        compressor.setParameters(threshold: -40, ratio: 4, attack: 10, release: 100, makeupGain: 0)
        let frames = 480  // 10 ms
        var data = [Float](repeating: 1.0, count: frames)
        data.withUnsafeMutableBufferPointer { compressor.process($0.baseAddress!, frameCount: frames) }
        // One time constant: envelope ~63% of the peak (block quantization tolerance)
        XCTAssertEqual(compressor.envelope, 0.63, accuracy: 0.08)
    }

    func testParameterChangeIsPickedUp() {
        let compressor = Compressor(sampleRate: 48000, channels: 1)
        compressor.setParameters(threshold: -20, ratio: 1, attack: 1, release: 100, makeupGain: 6)
        var data = [Float](repeating: 0.1, count: 64)
        data.withUnsafeMutableBufferPointer { compressor.process($0.baseAddress!, frameCount: 64) }
        XCTAssertEqual(data[0], 0.1 * powf(10, 6 / 20), accuracy: 1e-4)
    }
}

final class EqualizerTests: XCTestCase {
    func testFlatIsBitExactBypass() {
        let eq = Equalizer(sampleRate: 48000)
        eq.setGains([Float](repeating: 0, count: 8))
        let input = TestSignals.sine(frequency: 440, sampleRate: 48000, frames: 1024)
        var data = input
        data.withUnsafeMutableBufferPointer { eq.process($0.baseAddress!, frameCount: 1024, channels: 2) }
        XCTAssertEqual(data, input)
    }

    func testBoostAtBandCenter() {
        let eq = Equalizer(sampleRate: 48000)
        var gains = [Float](repeating: 0, count: 8)
        gains[4] = 12  // 1 kHz
        eq.setGains(gains)
        var data = TestSignals.sine(frequency: 1000, sampleRate: 48000, frames: 48000, amplitude: 0.1)
        data.withUnsafeMutableBufferPointer { eq.process($0.baseAddress!, frameCount: 48000, channels: 2) }
        let tail = Array(TestSignals.channel(data, 0, of: 2).suffix(24000))
        let gainDB = 20 * log10(TestSignals.rms(tail) / (0.1 / sqrtf(2)))
        // Neighbouring bands overlap a little at Q = 1, so allow +12..+13.5 dB
        XCTAssertEqual(gainDB, 12.6, accuracy: 0.9)
    }

    /// Changing a gain must not reset the filter state (that produced clicks).
    func testGainChangeIsContinuous() {
        let eq = Equalizer(sampleRate: 48000)
        var gains = [Float](repeating: 0, count: 8)
        gains[2] = 6
        eq.setGains(gains)
        var data = TestSignals.sine(frequency: 250, sampleRate: 48000, frames: 9600, amplitude: 0.3)
        data.withUnsafeMutableBufferPointer { ptr in
            eq.process(ptr.baseAddress!, frameCount: 4800, channels: 2)
            gains[2] = 7
            eq.setGains(gains)
            eq.process(ptr.baseAddress! + 4800 * 2, frameCount: 4800, channels: 2)
        }
        let left = TestSignals.channel(data, 0, of: 2)
        let jump = abs(left[4800] - left[4799])
        let typicalStep = abs(left[4700] - left[4699]) + abs(left[4701] - left[4700])
        XCTAssertLessThan(jump, typicalStep * 2 + 0.01)
    }

    func testConcurrentGainUpdatesAreSafe() {
        let eq = Equalizer(sampleRate: 48000)
        let done = expectation(description: "ui")
        DispatchQueue.global().async {
            for i in 0..<20_000 {
                eq.setGains((0..<8).map { Float(($0 + i) % 25 - 12) })
            }
            done.fulfill()
        }
        let input = TestSignals.sine(frequency: 300, sampleRate: 48000, frames: 512, amplitude: 0.1)
        for _ in 0..<2000 {
            var data = input
            data.withUnsafeMutableBufferPointer { eq.process($0.baseAddress!, frameCount: 512, channels: 2) }
            // +12 dB max on every band cannot exceed ~0.1 * 4^8 even with overlapping bands
            XCTAssertTrue(data.allSatisfy { $0.isFinite && abs($0) < 50 })
        }
        wait(for: [done], timeout: 10)
    }
}

final class MidSideKaraokeTests: XCTestCase {
    func testCenteredVocalBandIsRemoved() {
        let karaoke = MidSideKaraoke(sampleRate: 48000)
        var data = TestSignals.sine(frequency: 1000, sampleRate: 48000, frames: 48000, amplitude: 0.5)
        data.withUnsafeMutableBufferPointer { karaoke.process($0.baseAddress!, frameCount: 48000, channels: 2, intensity: 1) }
        let tail = Array(TestSignals.channel(data, 0, of: 2).suffix(24000))
        XCTAssertLessThan(TestSignals.rms(tail), 0.5 / sqrtf(2) * 0.35)
    }

    func testBassIsPreserved() {
        let karaoke = MidSideKaraoke(sampleRate: 48000)
        var data = TestSignals.sine(frequency: 40, sampleRate: 48000, frames: 48000, amplitude: 0.5)
        data.withUnsafeMutableBufferPointer { karaoke.process($0.baseAddress!, frameCount: 48000, channels: 2, intensity: 1) }
        let tail = Array(TestSignals.channel(data, 0, of: 2).suffix(24000))
        XCTAssertGreaterThan(TestSignals.rms(tail), 0.5 / sqrtf(2) * 0.85)
    }

    func testZeroIntensityIsTransparent() {
        let karaoke = MidSideKaraoke(sampleRate: 44100)
        let input = TestSignals.sine(frequency: 3000, sampleRate: 44100, frames: 4096)
        var data = input
        data.withUnsafeMutableBufferPointer { karaoke.process($0.baseAddress!, frameCount: 4096, channels: 2, intensity: 0) }
        for i in 0..<data.count { XCTAssertEqual(data[i], input[i], accuracy: 1e-5) }
    }
}

final class AudioVisualizerTests: XCTestCase {
    func testBinRangesAreValidForCommonRates() {
        for rate in [44100.0, 48000.0, 88200.0, 96000.0, 192000.0] {
            let ranges = AudioVisualizer.makeBinRanges(sampleRate: rate, fftSize: AudioVisualizer.fftSize)
            XCTAssertEqual(ranges.count, VisualizationTap.bandCount)
            var previousEnd = 1
            for range in ranges {
                XCTAssertGreaterThanOrEqual(range.start, previousEnd)
                XCTAssertGreaterThan(range.end, range.start)
                XCTAssertLessThanOrEqual(range.end, AudioVisualizer.fftSize / 2)
                previousEnd = range.end
            }
        }
    }

    func testSineLightsTheMatchingBand() throws {
        let tap = VisualizationTap()
        let visualizer = try XCTUnwrap(AudioVisualizer(sampleRate: 48000, tap: tap))
        let data = TestSignals.sine(frequency: 1200, sampleRate: 48000, frames: 48000 / 10, amplitude: 0.5)
        data.withUnsafeBufferPointer { visualizer.process($0.baseAddress!, frameCount: 4800, channels: 2) }
        var version: UInt64 = 0
        let bands = try XCTUnwrap(tap.readBands(lastVersion: &version))
        // Band 10 covers 1.0-1.4 kHz
        XCTAssertEqual(bands.firstIndex(of: bands.max()!), 10)
        XCTAssertNil(tap.readBands(lastVersion: &version), "No new frame without new audio")
        var scopeVersion: UInt64 = 0
        let scope = try XCTUnwrap(tap.readScope(lastVersion: &scopeVersion))
        XCTAssertEqual(scope.count, VisualizationTap.scopeCount)
        XCTAssertTrue(scope.allSatisfy { abs($0) <= 1 })
    }
}
