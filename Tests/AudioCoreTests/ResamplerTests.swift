import XCTest
@testable import AudioCore

final class ResamplerTests: XCTestCase {
    private func run(_ resampler: Resampler, input: [Float], channels: Int, blockSizes: [Int], ratio: Double = 1.0) -> [Float] {
        var output: [Float] = []
        var offset = 0
        var blockIndex = 0
        let maxBlock = blockSizes.max()!
        var scratch = [Float](repeating: 0, count: resampler.maxOutputFrames(forInputFrames: maxBlock) * channels)
        let totalFrames = input.count / channels
        while offset < totalFrames {
            let frames = min(blockSizes[blockIndex % blockSizes.count], totalFrames - offset)
            let produced = input.withUnsafeBufferPointer { inPtr in
                scratch.withUnsafeMutableBufferPointer { outPtr in
                    resampler.process(input: inPtr.baseAddress! + offset * channels, inputFrames: frames,
                                      ratioAdjustment: ratio, output: outPtr.baseAddress!,
                                      outputCapacity: outPtr.count / channels)
                }
            }
            output += scratch[0..<produced * channels]
            offset += frames
            blockIndex += 1
        }
        return output
    }

    /// The old resampler produced ceil(512 * 48000/44100) = 558 frames per 512-frame block (+0.13%).
    func testLongTermRateIsExact() {
        let resampler = Resampler(inputSampleRate: 44100, outputSampleRate: 48000, channels: 2)
        let blocks = 2000
        let input = [Float](repeating: 0.1, count: 512 * blocks * 2)
        let output = run(resampler, input: input, channels: 2, blockSizes: [512])
        let expected = Double(512 * blocks) * 48000 / 44100
        XCTAssertEqual(Double(output.count / 2), expected, accuracy: 3)
    }

    func testRatioAdjustmentChangesRate() {
        let resampler = Resampler(inputSampleRate: 48000, outputSampleRate: 44100, channels: 1)
        let input = [Float](repeating: 0, count: 512 * 1000)
        let output = run(resampler, input: input, channels: 1, blockSizes: [512], ratio: 1.001)
        let expected = Double(input.count) * 44100 / 48000 * 1.001
        XCTAssertEqual(Double(output.count), expected, accuracy: 3)
    }

    /// Phase continuity: output must not depend on how the input is split.
    func testOutputIndependentOfBlockSplitting() {
        let input = TestSignals.sine(frequency: 997, sampleRate: 44100, frames: 20_000)
        let a = run(Resampler(inputSampleRate: 44100, outputSampleRate: 48000, channels: 2),
                    input: input, channels: 2, blockSizes: [512])
        let b = run(Resampler(inputSampleRate: 44100, outputSampleRate: 48000, channels: 2),
                    input: input, channels: 2, blockSizes: [1, 7, 333, 64, 1024, 2])
        XCTAssertEqual(a.count, b.count)
        for i in 0..<min(a.count, b.count) {
            XCTAssertEqual(a[i], b[i], accuracy: 1e-5)
        }
    }

    func testSineIsReconstructedAccurately() {
        let inRate = 44100.0, outRate = 48000.0, freq = 1000.0
        let input = TestSignals.sine(frequency: freq, sampleRate: inRate, frames: 44100, channels: 1)
        let output = run(Resampler(inputSampleRate: inRate, outputSampleRate: outRate, channels: 1),
                         input: input, channels: 1, blockSizes: [512])
        // Output frame k corresponds to input position (k / ratio) - 2 (fixed latency)
        var maxError: Float = 0
        for k in 100..<(output.count - 100) {
            let t = (Double(k) * inRate / outRate - 2) / inRate
            let reference = 0.5 * Float(sin(2 * Double.pi * freq * t))
            maxError = max(maxError, abs(output[k] - reference))
        }
        XCTAssertLessThan(maxError, 0.002)
    }

    func testCapacityBoundIsRespected() {
        let resampler = Resampler(inputSampleRate: 22050, outputSampleRate: 96000, channels: 2)
        let frames = 4096
        let input = [Float](repeating: 0.2, count: frames * 2)
        let capacity = resampler.maxOutputFrames(forInputFrames: frames)
        var output = [Float](repeating: 0, count: capacity * 2)
        for _ in 0..<10 {
            let produced = input.withUnsafeBufferPointer { inPtr in
                output.withUnsafeMutableBufferPointer {
                    resampler.process(input: inPtr.baseAddress!, inputFrames: frames, ratioAdjustment: 1.001,
                                      output: $0.baseAddress!, outputCapacity: capacity)
                }
            }
            XCTAssertLessThan(produced, capacity)
        }
    }
}
