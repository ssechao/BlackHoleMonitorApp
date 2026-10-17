import Foundation

/// Streaming Catmull-Rom (cubic Hermite) resampler for interleaved audio.
///
/// The read position is tracked continuously across calls: conceptually each
/// call sees the stream `E = [last 3 frames of previous input] + input`, and an
/// output frame at position `p` needs `E[i-1 ... i+2]` with `i = floor(p)`.
/// Only frames whose four neighbours are known are produced, the remainder of
/// the position is carried to the next call. As a result the number of output
/// frames varies by ±1 between calls but the long-term rate is exactly
/// `outputRate / inputRate * ratioAdjustment`, with no phase jump at buffer
/// boundaries. Fixed latency: 2 input frames.
///
/// Real-time safe: no allocation after `init`.
final class Resampler {
    private static let historyFrames = 3

    let channels: Int
    let baseRatio: Double  // outputRate / inputRate

    private let history: UnsafeMutablePointer<Float>
    private var position: Double = 1.0

    init(inputSampleRate: Double, outputSampleRate: Double, channels: Int) {
        precondition(inputSampleRate > 0 && outputSampleRate > 0 && channels > 0)
        self.channels = channels
        self.baseRatio = outputSampleRate / inputSampleRate
        history = UnsafeMutablePointer<Float>.allocate(capacity: Self.historyFrames * channels)
        history.initialize(repeating: 0, count: Self.historyFrames * channels)
    }

    deinit {
        history.deallocate()
    }

    /// Upper bound of output frames produced for `inputFrames` input frames,
    /// for any ratio adjustment up to `maxAdjustment`.
    func maxOutputFrames(forInputFrames inputFrames: Int, maxAdjustment: Double = 1.01) -> Int {
        Int((Double(inputFrames + Self.historyFrames) * baseRatio * maxAdjustment).rounded(.up)) + 2
    }

    /// - Parameters:
    ///   - input: interleaved input frames
    ///   - ratioAdjustment: drift-correction multiplier (e.g. 1.0005 = +0.05% output)
    ///   - output: interleaved destination
    ///   - outputCapacity: capacity of `output` in frames
    /// - Returns: number of output frames written.
    func process(input: UnsafePointer<Float>, inputFrames: Int, ratioAdjustment: Double = 1.0,
                 output: UnsafeMutablePointer<Float>, outputCapacity: Int) -> Int {
        guard inputFrames > 0 else { return 0 }
        let step = 1.0 / (baseRatio * ratioAdjustment)
        let extendedFrames = inputFrames + Self.historyFrames
        var pos = position
        var produced = 0

        while produced < outputCapacity {
            let i = Int(pos)
            if i + 2 >= extendedFrames { break }
            let t = Float(pos - Double(i))
            let outBase = produced * channels
            for channel in 0..<channels {
                let s0 = sample(i - 1, channel, input)
                let s1 = sample(i, channel, input)
                let s2 = sample(i + 1, channel, input)
                let s3 = sample(i + 2, channel, input)
                output[outBase + channel] = Self.catmullRom(s0, s1, s2, s3, t)
            }
            produced += 1
            pos += step
        }

        // If the output buffer was too small, drop the unread part rather than drift.
        if Int(pos) + 2 < extendedFrames {
            pos = Double(extendedFrames - 2) + (pos - pos.rounded(.down))
        }
        position = pos - Double(inputFrames)

        // New history = last 3 frames of the extended stream. Ascending order is
        // safe in place: index `k` is only ever read from an index >= k.
        for k in 0..<Self.historyFrames {
            let e = inputFrames + k
            for channel in 0..<channels {
                history[k * channels + channel] = sample(e, channel, input)
            }
        }
        return produced
    }

    func reset() {
        position = 1.0
        history.update(repeating: 0, count: Self.historyFrames * channels)
    }

    @inline(__always)
    private func sample(_ extendedIndex: Int, _ channel: Int, _ input: UnsafePointer<Float>) -> Float {
        if extendedIndex < Self.historyFrames {
            return history[extendedIndex * channels + channel]
        }
        return input[(extendedIndex - Self.historyFrames) * channels + channel]
    }

    @inline(__always)
    static func catmullRom(_ s0: Float, _ s1: Float, _ s2: Float, _ s3: Float, _ t: Float) -> Float {
        let a = -0.5 * s0 + 1.5 * s1 - 1.5 * s2 + 0.5 * s3
        let b = s0 - 2.5 * s1 + 2.0 * s2 - 0.5 * s3
        let c = -0.5 * s0 + 0.5 * s2
        return ((a * t + b) * t + c) * t + s1
    }
}
