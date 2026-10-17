import Foundation

/// Interleaved test signals.
enum TestSignals {
    static func sine(frequency: Double, sampleRate: Double, frames: Int, channels: Int = 2,
                     amplitude: Float = 0.5, phase: Double = 0) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate + phase))
            for channel in 0..<channels {
                out[frame * channels + channel] = value
            }
        }
        return out
    }

    /// Frame `index` of every channel encodes the frame number, to check ordering.
    static func ramp(frames: Int, channels: Int, start: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                out[frame * channels + channel] = Float(start + frame) + Float(channel) * 0.25
            }
        }
        return out
    }

    static func channel(_ data: [Float], _ channel: Int, of channels: Int) -> [Float] {
        stride(from: channel, to: data.count, by: channels).map { data[$0] }
    }

    static func rms(_ data: [Float]) -> Float {
        guard !data.isEmpty else { return 0 }
        return (data.reduce(0) { $0 + $1 * $1 } / Float(data.count)).squareRoot()
    }
}
